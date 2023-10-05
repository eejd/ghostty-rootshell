export default function VTSequence({ sequence }) {
  return (
    <div className="flex my-2.5">
      <div className="border shrink px-1 grid grid-rows-2 grid-cols-1 text-center">
        <div>0x08</div>
        <div>{sequence}</div>
      </div>
    </div>
  );
}

const special = {
  BS: 0x08,
};
