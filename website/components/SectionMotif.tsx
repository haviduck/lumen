// Thin gradient hairline with a small accent diamond in the middle.
// Used between major sections to add visual rhythm without adding mass.
// Implementation is in globals.css under .section-motif.

export function SectionMotif() {
  return (
    <div className="section-motif py-4" aria-hidden>
      <span className="motif-mark" />
    </div>
  );
}
