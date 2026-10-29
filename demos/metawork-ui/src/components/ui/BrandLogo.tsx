import logoMarkUrl from "../../../assets/brand/logo-mark.svg?url";
import logoWordmarkUrl from "../../../assets/brand/logo-wordmark.svg?url";

export function BrandLogo({
  label,
  showMark = true,
}: {
  label: string;
  showMark?: boolean;
}) {
  return (
    <span className="brand-logo" role="img" aria-label={label}>
      {showMark && <img src={logoMarkUrl} alt="" />}
      <span
        className="brand-logo-wordmark"
        aria-hidden="true"
        style={{ maskImage: `url("${logoWordmarkUrl}")` }}
      />
    </span>
  );
}
