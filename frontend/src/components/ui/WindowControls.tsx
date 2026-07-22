import { Icon } from "./Icon.tsx";

export type WindowControlAction = "minimize" | "toggle_maximize" | "close";

export function WindowControls({
  labels,
  onAction,
}: {
  labels: {
    controls: string;
    minimize: string;
    maximize: string;
    close: string;
  };
  onAction: (action: WindowControlAction) => void;
}) {
  return (
    <div className="window-controls" role="group" aria-label={labels.controls}>
      <button
        type="button"
        aria-label={labels.minimize}
        title={labels.minimize}
        onClick={() => onAction("minimize")}
      >
        <Icon name="minimize" />
      </button>
      <button
        type="button"
        aria-label={labels.maximize}
        title={labels.maximize}
        onClick={() => onAction("toggle_maximize")}
      >
        <Icon name="maximize" />
      </button>
      <button
        type="button"
        className="window-control-close"
        aria-label={labels.close}
        title={labels.close}
        onClick={() => onAction("close")}
      >
        <Icon name="close" />
      </button>
    </div>
  );
}
