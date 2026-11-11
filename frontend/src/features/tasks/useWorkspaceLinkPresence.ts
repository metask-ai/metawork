import { useEffect, useRef, useState } from "react";
import type {
  FilePreviewLoadOptions,
  WorkspaceDirectory,
} from "../../bridge/contracts.ts";
import {
  workspaceFileParent,
  workspaceFilePresence,
} from "../../workbench/workspace-file-links.ts";

export type WorkspaceDirectoryLoader = (
  path: string,
  options: FilePreviewLoadOptions,
) => Promise<WorkspaceDirectory>;

type Listing = { epoch: string; directory: WorkspaceDirectory | null };

const maxDirectories = 64;
const noListings: ReadonlyMap<string, Listing> = new Map();

// Confirms conversation Workspace links through the file tree's Host listing,
// one directory at a time so interactive previews keep the shared preparation
// slots. Results are bound to the Task/Workspace/connection scope; a new file
// epoch re-checks shown directories while the previous answer stays visible.
// There is no polling: unknown, pending and over-capacity paths stay openable.
export function useWorkspaceLinkPresence(
  scope: string | null,
  epoch: string,
  load: WorkspaceDirectoryLoader | undefined,
) {
  const [stored, setStored] = useState<{
    scope: string | null;
    listings: ReadonlyMap<string, Listing>;
  }>({ scope: null, listings: noListings });
  const listings = stored.scope === scope ? stored.listings : noListings;
  const shown = useRef(new Set<string>());
  const queued = useRef<string[]>([]);
  const admitted = useRef(new Set<string>());
  const running = useRef<{
    controller: AbortController;
    directory: string;
    epoch: string;
  } | null>(null);
  const latest = useRef({ scope, epoch, load });
  latest.current = { scope, epoch, load };

  useEffect(() => {
    queued.current = [];
    admitted.current.clear();
    return () => {
      const unfinished = [...queued.current];
      if (running.current) unfinished.push(running.current.directory);
      running.current?.controller.abort();
      running.current = null;
      // A replayed mount of the same scope (React StrictMode) resumes the
      // unfinished directories; a new scope only checks what it shows.
      if (latest.current.scope === scope)
        for (const directory of unfinished) shown.current.add(directory);
    };
  }, [scope]);

  function next() {
    const current = latest.current;
    if (running.current || !current.scope || !current.load) return;
    const directory = queued.current.shift();
    if (directory === undefined) return;
    const request = {
      controller: new AbortController(),
      directory,
      epoch: current.epoch,
    };
    running.current = request;
    void current
      .load(directory, {
        signal: request.controller.signal,
        priority: "prefetch",
      })
      .catch(() => null)
      .then((result) => {
        if (running.current !== request) return;
        running.current = null;
        setStored((value) => ({
          scope: current.scope,
          listings: new Map(
            value.scope === current.scope ? value.listings : [],
          ).set(directory, { epoch: request.epoch, directory: result }),
        }));
        next();
      });
  }

  // Links report their directory while rendering; schedule after each commit.
  useEffect(() => {
    for (const directory of shown.current) {
      if (
        listings.get(directory)?.epoch === epoch ||
        queued.current.includes(directory) ||
        (running.current?.directory === directory &&
          running.current.epoch === epoch)
      )
        continue;
      if (!admitted.current.has(directory)) {
        if (admitted.current.size >= maxDirectories) continue;
        admitted.current.add(directory);
      }
      queued.current.push(directory);
    }
    shown.current.clear();
    next();
  });

  return (path: string): "present" | "missing" | "unknown" => {
    const { directory, name } = workspaceFileParent(path);
    shown.current.add(directory);
    const listing = listings.get(directory)?.directory;
    return listing ? workspaceFilePresence(listing, name) : "unknown";
  };
}
