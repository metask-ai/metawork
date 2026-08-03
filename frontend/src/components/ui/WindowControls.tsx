import { Icon } from "./Icon.tsx";

export type WindowControlAction = "minimize" | "toggle_maximize" | "close";

export function WindowControls({
  maximized,
  labels,
  onAction,
}: {
  maximized: boolean;
  labels: {
    controls: string;
    minimize: string;
    maximize: string;
    restore: string;
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
        aria-label={maximized ? labels.restore : labels.maximize}
        title={maximized ? labels.restore : labels.maximize}
        onClick={() => onAction("toggle_maximize")}
      >
        <Icon name={maximized ? "restore" : "maximize"} />
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
