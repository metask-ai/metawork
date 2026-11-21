import logoMarkUrl from "../../../../assets/brand/logo-mark.svg?url";
import logoWordmarkUrl from "../../../../assets/brand/logo-wordmark.svg?url";

export function BrandLogo({
  label,
  markOnly = false,
}: {
  label: string;
  markOnly?: boolean;
}) {
  return (
    <span className="brand-logo" role="img" aria-label={label}>
      <img src={logoMarkUrl} alt="" />
      {!markOnly && (
        <span
          className="brand-logo-wordmark"
          aria-hidden="true"
          style={{ maskImage: `url("${logoWordmarkUrl}")` }}
        />
      )}
    </span>
  );
}
