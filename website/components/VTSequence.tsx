// Draw a diagram showing the VT sequence.
export default function VTSequence({
  sequence,
}: {
  sequence: string | [string];
}) {
  // TODO: handle sequence array
  const elem = typeof sequence === "string" ? sequence : sequence[0];

  const specialChar = special[elem] ?? 0;
  const hex = specialChar.toString(16).padStart(2, "0");

  return (
    <div className="flex my-2.5">
      <div className="border shrink px-1 grid grid-rows-2 grid-cols-1 text-center">
        <div>0x{hex}</div>
        <div>{sequence}</div>
      </div>
    </div>
  );
}

const special: { [key: string]: number } = {
  BEL: 0x07,
  BS: 0x08,
};
