import logoMarkUrl from "../../../../assets/brand/logo-mark.svg?url";
import { productVersion } from "../../app/product-identity.ts";
import { Dialog } from "../../components/ui/dialog.tsx";
import { Icon } from "../../components/ui/Icon.tsx";
import { useI18n } from "../../i18n/context.ts";

export function AboutMetaWorkDialog({
  open,
  onOpenChange,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
}) {
  const { t } = useI18n();

  return (
    <Dialog.Root open={open} onOpenChange={onOpenChange}>
      <Dialog.Portal>
        <Dialog.Backdrop />
        <Dialog.Popup className="about-dialog">
          <Dialog.Close
            className="about-dialog-close"
            aria-label={t("common.close")}
          >
            <Icon name="close" />
          </Dialog.Close>

          <div className="about-dialog-product">
            <span className="about-dialog-mark" aria-hidden="true">
              <img src={logoMarkUrl} alt="" />
            </span>
            <div>
              <Dialog.Title>{t("app.name")}</Dialog.Title>
            </div>
          </div>

          <dl className="about-dialog-build">
            <div>
              <dt>{t("about.version")}</dt>
              <dd>
                <code>{productVersion}</code>
              </dd>
            </div>
          </dl>
        </Dialog.Popup>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
