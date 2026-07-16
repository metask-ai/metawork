import { useCallback, useRef, useState } from "react";

import type { WorkbenchSnapshot } from "../../host/contracts.ts";
import {
  acceptUiResponse,
  beginUiResponse,
  failUiResponse,
  initialUiResponseStates,
  observeUiResponseSnapshot,
  snapshotHasUiRequest,
  uiRequestKey,
  type UiRequestIdentity,
  type UiResponseStates,
} from "./response-state.ts";

export function useUiResponseStates() {
  const [states, setStates] = useState<UiResponseStates>(
    initialUiResponseStates,
  );
  const lockedRequests = useRef(new Map<string, UiRequestIdentity>());
  const latestSnapshot = useRef<WorkbenchSnapshot | null>(null);

  const begin = useCallback((identity: UiRequestIdentity) => {
    const key = uiRequestKey(identity);
    if (
      latestSnapshot.current &&
      !snapshotHasUiRequest(latestSnapshot.current, identity)
    )
      return false;
    if (lockedRequests.current.has(key)) return false;
    lockedRequests.current.set(key, identity);
    setStates((current) => beginUiResponse(current, identity));
    return true;
  }, []);

  const accepted = useCallback((identity: UiRequestIdentity) => {
    setStates((current) => acceptUiResponse(current, identity));
  }, []);

  const failed = useCallback((identity: UiRequestIdentity) => {
    lockedRequests.current.delete(uiRequestKey(identity));
    setStates((current) => failUiResponse(current, identity));
  }, []);

  const observeSnapshot = useCallback((snapshot: WorkbenchSnapshot) => {
    latestSnapshot.current = snapshot;
    for (const [key, identity] of lockedRequests.current) {
      if (snapshotHasUiRequest(snapshot, identity)) continue;
      lockedRequests.current.delete(key);
    }
    setStates((current) => observeUiResponseSnapshot(current, snapshot));
  }, []);

  return { states, begin, accepted, failed, observeSnapshot };
}
