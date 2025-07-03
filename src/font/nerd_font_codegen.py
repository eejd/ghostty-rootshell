"""
This file is mostly vibe coded because I don't like Python. It extracts the
patch sets from the nerd fonts font patcher file in order to extract scaling
rules and attributes for different codepoint ranges which it then codegens
in to a Zig file with a function that switches over codepoints and returns
the attributes and scaling rules.

This does include an `eval` call! This is spooky, but we trust
the nerd fonts code to be safe and not malicious or anything.
"""

import ast
import math
from pathlib import Path
from collections import defaultdict


class PatchSetExtractor(ast.NodeVisitor):
    def __init__(self):
        self.symbol_table = {}
        self.patch_set_values = []

    def visit_ClassDef(self, node):
        if node.name == "font_patcher":
            for item in node.body:
                if isinstance(item, ast.FunctionDef) and item.name == "setup_patch_set":
                    self.visit_setup_patch_set(item)

    def visit_setup_patch_set(self, node):
        # First pass: gather variable assignments
        for stmt in node.body:
            if isinstance(stmt, ast.Assign):
                # Store simple variable assignments in the symbol table
                if len(stmt.targets) == 1 and isinstance(stmt.targets[0], ast.Name):
                    var_name = stmt.targets[0].id
                    self.symbol_table[var_name] = stmt.value

        # Second pass: process self.patch_set
        for stmt in node.body:
            if isinstance(stmt, ast.Assign):
                for target in stmt.targets:
                    if isinstance(target, ast.Attribute) and target.attr == "patch_set":
                        if isinstance(stmt.value, ast.List):
                            for elt in stmt.value.elts:
                                if isinstance(elt, ast.Dict):
                                    self.process_patch_entry(elt)

    def resolve_symbol(self, node):
        """Resolve named variables to their actual values from the symbol table."""
        if isinstance(node, ast.Name) and node.id in self.symbol_table:
            return self.safe_literal_eval(self.symbol_table[node.id])
        return self.safe_literal_eval(node)

    def safe_literal_eval(self, node):
        """Try to evaluate or stringify an AST node."""
        try:
            return ast.literal_eval(node)
        except Exception:
            # Spooky eval! But we trust nerd fonts to be safe...
            if hasattr(ast, "unparse"):
                return eval(
                    ast.unparse(node), {"box_keep": True}, {"self": SpoofSelf()}
                )
            else:
                return f"<cannot eval: {type(node).__name__}>"

    def process_patch_entry(self, dict_node):
        entry = {}
        for key_node, value_node in zip(dict_node.keys, dict_node.values):
            if isinstance(key_node, ast.Constant) and key_node.value in (
                "Enabled",
                "Name",
                "Filename",
                "Exact",
            ):
                continue
            key = ast.literal_eval(key_node)
            value = self.resolve_symbol(value_node)
            entry[key] = value
        self.patch_set_values.append(entry)


def extract_patch_set_values(source_code):
    tree = ast.parse(source_code)
    extractor = PatchSetExtractor()
    extractor.visit(tree)
    return extractor.patch_set_values


# We have to spoof `self` and `self.args` for the eval.
class SpoofArgs:
    careful = True


class SpoofSelf:
    args = SpoofArgs()


def parse_alignment(val):
    return {
        "l": ".start",
        "r": ".end",
        "c": ".center",
        "": None,
    }.get(val, ".none")


def get_param(d, key, default):
    return float(d.get(key, default))


def attr_key(attr):
    """Convert attributes to a hashable key for grouping."""
    stretch = attr.get("stretch", "")
    return (
        parse_alignment(attr.get("align", "")),
        parse_alignment(attr.get("valign", "")),
        stretch,
        float(attr.get("params", {}).get("overlap", 0.0)),
        float(attr.get("params", {}).get("xy-ratio", -1.0)),
        float(attr.get("params", {}).get("ypadding", 0.0)),
    )


def coalesce_codepoints_to_ranges(codepoints):
    """Convert a sorted list of integers to a list of single values and ranges."""
    ranges = []
    cp_iter = iter(sorted(codepoints))
    try:
        start = prev = next(cp_iter)
        for cp in cp_iter:
            if cp == prev + 1:
                prev = cp
            else:
                ranges.append((start, prev))
                start = prev = cp
        ranges.append((start, prev))
    except StopIteration:
        pass
    return ranges


def emit_zig_entry_multikey(codepoints, attr):
    align = parse_alignment(attr.get("align", ""))
    valign = parse_alignment(attr.get("valign", ""))
    stretch = attr.get("stretch", "")
    params = attr.get("params", {})

    overlap = get_param(params, "overlap", 0.0)
    xy_ratio = get_param(params, "xy-ratio", -1.0)
    y_padding = get_param(params, "ypadding", 0.0)

    ranges = coalesce_codepoints_to_ranges(codepoints)
    keys = "\n".join(
        f"        0x{start:x}...0x{end:x}," if start != end else f"        0x{start:x},"
        for start, end in ranges
    )

    s = f"""{keys}
        => .{{\n"""

    # These translations don't quite capture the way
    # the actual patcher does scaling, but they're a
    # good enough compromise.
    if ("xy" in stretch):
        s += "            .size_horizontal = .stretch,\n"
        s += "            .size_vertical = .stretch,\n"
    elif ("!" in stretch):
        s += "            .size_horizontal = .cover,\n"
        s += "            .size_vertical = .fit,\n"
    elif ("^" in stretch):
        s += "            .size_horizontal = .cover,\n"
        s += "            .size_vertical = .cover,\n"
    else:
        s += "            .size_horizontal = .fit,\n"
        s += "            .size_vertical = .fit,\n"

    if (align is not None):
        s += f"            .align_horizontal = {align},\n"
    if (valign is not None):
        s += f"            .align_vertical = {valign},\n"

    if (overlap != 0.0):
        pad = -overlap
        s += f"            .pad_left = {pad},\n"
        s += f"            .pad_right = {pad},\n"
        v_pad = y_padding - math.copysign(min(0.01, abs(overlap)), overlap)
        s += f"            .pad_top = {v_pad},\n"
        s += f"            .pad_bottom = {v_pad},\n"

    if (xy_ratio > 0):
        s += f"            .max_xy_ratio = {xy_ratio},\n"

    s += "        },"

    return s

def generate_zig_switch_arms(patch_set):
    entries = {}
    for entry in patch_set:
        attributes = entry["Attributes"]

        for cp in range(entry["SymStart"], entry["SymEnd"] + 1):
            entries[cp] = attributes["default"]

        for k, v in attributes.items():
            if isinstance(k, int):
                entries[k] = v

    del entries[0]

    # Group codepoints by attribute key
    grouped = defaultdict(list)
    for cp, attr in entries.items():
        grouped[attr_key(attr)].append(cp)

    # Emit zig switch arms
    result = []
    for _, codepoints in sorted(grouped.items(), key=lambda x: x[1]):
        # Use one of the attrs in the group to emit the value
        attr = entries[codepoints[0]]
        result.append(emit_zig_entry_multikey(codepoints, attr))

    return "\n".join(result)


if __name__ == "__main__":
    path = (
        Path(__file__).resolve().parent
        / ".."
        / ".."
        / "vendor"
        / "nerd-fonts"
        / "font-patcher.py"
    )
    with open(path, "r", encoding="utf-8") as f:
        source = f.read()

    patch_set = extract_patch_set_values(source)

    out_path = Path(__file__).resolve().parent / "nerd_font_attributes.zig"

    with open(out_path, "w", encoding="utf-8") as f:
        f.write("""//! This is a generate file, produced by nerd_font_codegen.py
//! DO NOT EDIT BY HAND!
//!
//! This file provides info extracted from the nerd fonts patcher script,
//! specifying the scaling/positioning attributes of various glyphs.

const Constraint = @import("face.zig").RenderOptions.Constraint;

/// Get the a constraints for the provided codepoint.
pub fn getConstraint(cp: u21) Constraint {
    return switch (cp) {
""")
        f.write(generate_zig_switch_arms(patch_set))
        f.write("\n")

        f.write("        else => .none,\n    };\n}\n")
