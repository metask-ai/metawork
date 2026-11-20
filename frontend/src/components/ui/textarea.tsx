import {
  forwardRef,
  useEffect,
  type RefObject,
  type TextareaHTMLAttributes,
} from "react";

import { cn, controlBase, controlFocus } from "./utils.ts";

export const Textarea = forwardRef<
  HTMLTextAreaElement,
  TextareaHTMLAttributes<HTMLTextAreaElement>
>(({ className, ...props }, ref) => (
  <textarea
    ref={ref}
    className={cn(
      "min-h-24 w-full resize-y rounded-[7px] px-3 py-2 text-sm",
      controlBase,
      controlFocus,
      className,
    )}
    {...props}
  />
));
Textarea.displayName = "Textarea";

function resizeTextarea(textarea: HTMLTextAreaElement) {
  const maxHeight = Math.min(180, window.innerHeight * 0.28);
  textarea.style.height = "auto";
  const contentHeight = textarea.scrollHeight;
  textarea.style.height = `${Math.min(contentHeight, maxHeight)}px`;
  textarea.style.overflowY = contentHeight > maxHeight ? "auto" : "hidden";
}

export function useAutosizeTextarea(
  ref: RefObject<HTMLTextAreaElement | null>,
  text: string | undefined,
) {
  const visible = text !== undefined;

  useEffect(() => {
    const textarea = ref.current;
    if (textarea && text !== undefined) resizeTextarea(textarea);
  }, [ref, text]);

  useEffect(() => {
    const textarea = ref.current;
    if (!visible || !textarea) return;
    const resize = () => resizeTextarea(textarea);
    const observer =
      typeof ResizeObserver === "undefined" ? null : new ResizeObserver(resize);
    observer?.observe(textarea);
    window.addEventListener("resize", resize);
    return () => {
      observer?.disconnect();
      window.removeEventListener("resize", resize);
    };
  }, [ref, visible]);
}
