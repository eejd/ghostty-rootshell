import "@/styles/code.css";

export default function Layout({ children }: { children: React.ReactNode }) {
  return (
    <div className="flex justify-center font-mono mt-8">
      <div className="flex-1"></div>
      <div className="w-1/2 max-w-[800px] prose prose-h1:text-base prose-h1:font-bold prose-h2:text-base prose-h2:font-bold prose-p:text-base prose-h1:m-0 prose-h1:mb-1.5 prose-h2:m-0 prose-h2:mb-1.5 prose-invert">
        {children}
      </div>
      <div className="flex-1"></div>
    </div>
  );
}
