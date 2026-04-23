const builtin = @import("builtin");
const std = @import("std");
const Target = std.Target;
const HwyTargets = @import("targets.zig").Targets;

/// Detect Highway targets using Zig's standard library CPU feature detection.
///
/// The logic is mostly identical to the Highway implementation, but we
/// use Zig's built-in CPU feature detection instead of Highway so that we
/// can strictly control access to Apple headers (and avoid them completely).
pub export fn ghostty_hwy_detect_targets() callconv(.c) i64 {
    const native = std.zig.system.resolveTargetQuery(.{}) catch return 0;
    const cpu = native.cpu;

    return switch (builtin.cpu.arch) {
        .x86_64, .x86 => detectX86(cpu),
        .aarch64, .aarch64_be => detectAarch64(cpu),
        else => 0,
    };
}

fn detectX86(cpu: Target.Cpu) i64 {
    var t: HwyTargets = .{};

    if (comptime builtin.cpu.arch == .x86_64) {
        t.sse2 = true;
    }

    if (comptime builtin.cpu.arch == .x86) {
        if (cpu.has(.x86, .sse) and
            cpu.has(.x86, .sse2))
        {
            t.sse2 = true;
        }
    }

    if (cpu.has(.x86, .sse3) and
        cpu.has(.x86, .ssse3))
    {
        t.ssse3 = true;
    }

    if (cpu.has(.x86, .sse4_1) and
        cpu.has(.x86, .sse4_2) and
        cpu.has(.x86, .pclmul) and
        cpu.has(.x86, .aes))
    {
        t.sse4 = true;
    }

    if (cpu.has(.x86, .avx) and
        cpu.has(.x86, .avx2) and
        cpu.has(.x86, .lzcnt) and
        cpu.has(.x86, .bmi) and
        cpu.has(.x86, .bmi2) and
        cpu.has(.x86, .fma) and
        cpu.has(.x86, .f16c))
    {
        t.avx2 = true;
    }

    if (cpu.has(.x86, .avx512f) and
        cpu.has(.x86, .avx512vl) and
        cpu.has(.x86, .avx512dq) and
        cpu.has(.x86, .avx512bw) and
        cpu.has(.x86, .avx512cd))
    {
        t.avx3 = true;
    }

    if (cpu.has(.x86, .avx512vnni) and
        cpu.has(.x86, .vpclmulqdq) and
        cpu.has(.x86, .avx512vbmi) and
        cpu.has(.x86, .avx512vbmi2) and
        cpu.has(.x86, .vaes) and
        cpu.has(.x86, .avx512vpopcntdq) and
        cpu.has(.x86, .avx512bitalg) and
        cpu.has(.x86, .gfni))
    {
        t.avx3_dl = true;
    }

    if (t.avx3_dl and cpu.has(.x86, .avx512bf16)) {
        if (isAMD()) {
            t.avx3_zen4 = true;
        }
    }

    if (cpu.has(.x86, .avx512fp16) and
        cpu.has(.x86, .avx512bf16))
    {
        t.avx3_spr = true;
    }

    if (cpu.has(.x86, .avx10_1_256)) {
        if (cpu.has(.x86, .avx10_1_512)) {
            t.avx3_spr = true;
            t.avx3_dl = true;
            t.avx3 = true;
        }

        if (cpu.has(.x86, .avx10_2_256)) {
            t.avx10_2 = true;
            if (cpu.has(.x86, .avx10_2_512)) {
                t.avx10_2_512 = true;
            }
        }
    }

    // Darwin lazily saves AVX512 context on first use, so the XCR0 check
    // is handled by Zig's feature detection (which hardcodes has_avx512_save
    // to true on Darwin, matching LLVM's approach).

    return @bitCast(t);
}

fn detectAarch64(cpu: Target.Cpu) i64 {
    var t: HwyTargets = .{};

    t.neon_without_aes = true;

    if (cpu.has(.aarch64, .aes)) {
        t.neon = true;

        if (cpu.has(.aarch64, .fullfp16) and
            cpu.has(.aarch64, .dotprod) and
            cpu.has(.aarch64, .bf16))
        {
            t.neon_bf16 = true;
        }
    }

    return @bitCast(t);
}

/// Check CPUID vendor string for "AuthenticAMD", matching Highway's IsAMD().
/// Zig doesn't expose the vendor string, so we must use inline assembly.
fn isAMD() bool {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [_] "={eax}" (eax),
          [_] "={ebx}" (ebx),
          [_] "={ecx}" (ecx),
          [_] "={edx}" (edx),
        : [_] "{eax}" (0),
    );

    // "Auth" "enti" "cAMD"
    return ebx == 0x68747541 and
        ecx == 0x444d4163 and
        edx == 0x69746e65;
}
