// Verified against Pi 0.81.1 and 0.82.0, which export AssistantMessageComponent with
// updateContent and render methods. installCalmAssistantLayout() probes those exact
// methods and throws if either is missing; fm-calm.ts catches that and skips only this
// adapter with a diagnostic instead of blocking Calm or Pi. It changes only presentation:
// it collapses hidden thinking, and it collapses the single routine no-action
// acknowledgement AGENTS.md section 9 defines, but ONLY when that assistant row answers a
// typed Firstmate operational input (fm-calm-visibility.ts owns that provenance) and its
// text is exactly that acknowledgement - never a captain-authored reply, a real outcome,
// or a superficially similar sentence in ordinary conversation.
import type { AssistantMessageComponent as PiAssistantMessageComponent } from "@earendil-works/pi-coding-agent";
import * as PiCodingAgent from "@earendil-works/pi-coding-agent";
import {
  calmPresentationHides,
  FIRSTMATE_OPERATIONAL_ACK,
  lastUserMessageWasFirstmateOperational,
} from "./fm-calm-visibility.ts";

type AssistantMessage = Parameters<PiAssistantMessageComponent["updateContent"]>[0];

type AssistantMessagePresentationState = {
  hiddenThinkingLabel: string;
  hideThinkingBlock: boolean;
  lastMessage?: AssistantMessage;
  // Captured once, at this component's first content update, from the provenance
  // of the message that immediately preceded it: true only when this assistant
  // row answers a typed Firstmate operational input. Undefined until captured.
  firstmateOperationalReply?: boolean;
};

type CalmAssistantLayoutPatch = {
  hidesThinking: () => boolean;
  hidesOperationalAck: () => boolean;
};

// Keep the introduction-version symbol stable so a compatible upgrade cannot
// double-patch a live process.
const CALM_ASSISTANT_LAYOUT_PATCH = Symbol.for(
  "firstmate:calm-assistant-layout:pi-0.81.1",
);

// The assistant response's visible text, or "" when it carries any tool call (a
// routine acknowledgement never does). Joins text blocks and trims so the exact
// comparison ignores a trailing newline the model may emit; thinking blocks are
// deliberately excluded because Calm already collapses them.
function assistantResponseText(message: AssistantMessage): string {
  let text = "";
  for (const block of message.content) {
    if (block.type === "toolCall") return "";
    if (block.type === "text") text += block.text;
  }
  return text.trim();
}

export function installCalmAssistantLayout(): void {
  const registry = globalThis as typeof globalThis & {
    [key: symbol]: CalmAssistantLayoutPatch | undefined;
  };
  const hidesThinking = (): boolean => calmPresentationHides("assistant-thinking");
  const hidesOperationalAck = (): boolean => calmPresentationHides("synthetic-assistant");
  const installed = registry[CALM_ASSISTANT_LAYOUT_PATCH];
  if (installed) {
    installed.hidesThinking = hidesThinking;
    installed.hidesOperationalAck = hidesOperationalAck;
    return;
  }

  const patch: CalmAssistantLayoutPatch = { hidesThinking, hidesOperationalAck };
  const AssistantMessageComponent = PiCodingAgent.AssistantMessageComponent;
  if (typeof AssistantMessageComponent !== "function") {
    throw new Error("Firstmate Calm requires Pi AssistantMessageComponent");
  }
  const prototype = AssistantMessageComponent.prototype;
  const originalUpdateContent = prototype.updateContent;
  if (typeof originalUpdateContent !== "function") {
    throw new Error("Firstmate Calm requires Pi AssistantMessageComponent.updateContent");
  }
  const originalRender = prototype.render;
  if (typeof originalRender !== "function") {
    throw new Error("Firstmate Calm requires Pi AssistantMessageComponent.render");
  }

  prototype.updateContent = function (message: AssistantMessage): void {
    const state = this as unknown as AssistantMessagePresentationState;
    // Capture provenance once, at message_start (or, for a restored row, in the
    // constructor's own first updateContent), when the shared flag still reflects
    // the message that preceded this assistant.
    if (state.firstmateOperationalReply === undefined) {
      state.firstmateOperationalReply = lastUserMessageWasFirstmateOperational();
    }
    const hideThinking =
      state.hiddenThinkingLabel === "" &&
      state.hideThinkingBlock &&
      patch.hidesThinking();
    const presentationMessage = hideThinking
      ? {
          ...message,
          content: message.content.filter((block) => block.type !== "thinking"),
        }
      : message;

    originalUpdateContent.call(this, presentationMessage);
    if (presentationMessage !== message) state.lastMessage = message;
  };

  prototype.render = function (width: number): string[] {
    const state = this as unknown as AssistantMessagePresentationState;
    if (
      patch.hidesOperationalAck() &&
      state.firstmateOperationalReply === true &&
      state.lastMessage !== undefined &&
      assistantResponseText(state.lastMessage) === FIRSTMATE_OPERATIONAL_ACK
    ) {
      return [];
    }
    return originalRender.call(this, width);
  };

  registry[CALM_ASSISTANT_LAYOUT_PATCH] = patch;
}
