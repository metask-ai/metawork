import type { ReactNode } from "react";
import { Dialog } from "./ui/dialog.tsx";
import { Icon } from "./ui/Icon.tsx";
import { Button } from "./ui/button.tsx";
import { useI18n } from "../i18n/context.ts";

/// The enlarged-image overlay shared by the attachment viewer and the file
/// panel's image preview: a titled popup with a close button around whatever
/// image view the caller supplies. It must be rendered inside a Dialog.Root.
export function ImageLightboxPopup({
  name,
  children,
}: {
  name: string;
  children: ReactNode;
}) {
  const { t } = useI18n();
  return (
    <Dialog.Portal>
      <Dialog.Backdrop />
      <Dialog.Popup className="media-lightbox">
        <div className="media-lightbox-bar">
          <Dialog.Title className="media-lightbox-title" dir="auto">
            {name}
          </Dialog.Title>
          <Dialog.Close
            render={
              <Button
                type="button"
                variant="ghost"
                size="icon"
                aria-label={t("attachment.close_preview")}
              >
                <Icon name="close" />
              </Button>
            }
          />
        </div>
        <div className="media-lightbox-body">{children}</div>
      </Dialog.Popup>
    </Dialog.Portal>
  );
}
