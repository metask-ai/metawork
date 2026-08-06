import { Icon } from "./Icon.tsx";

export type WindowControlAction = "minimize" | "toggle_maximize" | "close";

export function WindowControls({
  labels,
}: {
  labels: {
    controls: string;
    minimize: string;
    maximize: string;
    restore: string;
    close: string;
  };
}) {
  return (
    <div className="window-controls" role="group" aria-label={labels.controls}>
      <button
        type="button"
        aria-label={labels.minimize}
        title={labels.minimize}
        data-metawork-window-control="minimize"
      >
        <Icon name="minimize" />
      </button>
      <button
        type="button"
        className="window-control-maximize"
        aria-label={labels.maximize}
        title={labels.maximize}
        data-metawork-window-control="toggle_maximize"
      >
        <Icon name="maximize" />
      </button>
      <button
        type="button"
        className="window-control-restore"
        aria-label={labels.restore}
        title={labels.restore}
        data-metawork-window-control="toggle_maximize"
      >
        <Icon name="restore" />
      </button>
      <button
        type="button"
        className="window-control-close"
        aria-label={labels.close}
        title={labels.close}
        data-metawork-window-control="close"
      >
        <Icon name="close" />
      </button>
    </div>
  );
}
