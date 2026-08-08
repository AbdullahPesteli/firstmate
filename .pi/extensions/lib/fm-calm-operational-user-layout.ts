// Verified against Pi 0.81.1 and 0.82.0, which add the ordinary-user spacer and row
// together via InteractiveMode.addMessageToChat. This adapter probes that exact method
// and throws if it is missing; fm-calm.ts catches that and skips only this adapter with a
// diagnostic instead of blocking Calm or Pi. It changes only that presentation and never
// message delivery.
import type { UserMessageComponent as PiUserMessageComponent } from "@earendil-works/pi-coding-agent";
import * as PiCodingAgent from "@earendil-works/pi-coding-agent";
import {
  calmPresentationHides,
  noteFirstmateOperationalUserProvenance,
} from "./fm-calm-visibility.ts";
import { classifyFirstmateCurrentOperationalText } from "./fm-operational-input.ts";

type UserMessageConstructorArgs = ConstructorParameters<typeof PiUserMessageComponent>;
type UserMessageLike = {
  role: string;
  content: unknown;
};
type AddMessageOptions = {
  populateHistory?: boolean;
};
type InteractiveModePresentation = {
  chatContainer: {
    children: unknown[];
    addChild(component: PiUserMessageComponent): void;
  };
  editor: {
    addToHistory?(text: string): void;
  };
  getMarkdownThemeWithSettings(): UserMessageConstructorArgs[1];
  getUserMessageText(message: UserMessageLike): string;
  outputPad: number;
};
type InteractiveModePrototype = {
  addMessageToChat(
    this: InteractiveModePresentation,
    message: UserMessageLike,
    options?: AddMessageOptions,
  ): void;
};
type CalmOperationalUserLayoutPatch = {
  hidesOperationalInput: () => boolean;
  isOperationalInput: (text: string) => boolean;
  noteUserProvenance: (operational: boolean) => void;
};

// Keep the introduction-version symbol stable so a compatible upgrade cannot
// double-patch a live process.
const CALM_OPERATIONAL_USER_LAYOUT_PATCH = Symbol.for(
  "firstmate:calm-operational-user-layout:pi-0.81.1",
);
const LEGACY_CALM_OPERATIONAL_PREFIX = "\u2063Supervisor escalate (";

function contentIsTextOnly(content: unknown): boolean {
  if (typeof content === "string") return true;
  if (!Array.isArray(content) || content.length === 0) return false;
  return content.every(
    (block) =>
      typeof block === "object" &&
      block !== null &&
      (block as { type?: unknown }).type === "text" &&
      typeof (block as { text?: unknown }).text === "string",
  );
}

export function installCalmOperationalUserLayout(): void {
  const registry = globalThis as typeof globalThis & {
    [key: symbol]: CalmOperationalUserLayoutPatch | undefined;
  };
  const hidesOperationalInput = (): boolean => calmPresentationHides("synthetic-user");
  const isOperationalInput = (text: string): boolean => {
    if (!text.includes("\u2063")) return false;
    return (
      classifyFirstmateCurrentOperationalText(text) !== undefined ||
      text.startsWith(LEGACY_CALM_OPERATIONAL_PREFIX)
    );
  };
  const installed = registry[CALM_OPERATIONAL_USER_LAYOUT_PATCH];
  if (installed) {
    installed.hidesOperationalInput = hidesOperationalInput;
    installed.isOperationalInput = isOperationalInput;
    installed.noteUserProvenance = noteFirstmateOperationalUserProvenance;
    return;
  }

  const patch: CalmOperationalUserLayoutPatch = {
    hidesOperationalInput,
    isOperationalInput,
    noteUserProvenance: noteFirstmateOperationalUserProvenance,
  };
  const InteractiveMode = PiCodingAgent.InteractiveMode;
  if (typeof InteractiveMode !== "function") {
    throw new Error("Firstmate Calm requires Pi InteractiveMode");
  }
  const prototype = InteractiveMode.prototype as unknown as InteractiveModePrototype;
  const originalAddMessageToChat = prototype.addMessageToChat;
  if (typeof originalAddMessageToChat !== "function") {
    throw new Error("Firstmate Calm requires Pi InteractiveMode.addMessageToChat");
  }

  const UserMessageComponent = PiCodingAgent.UserMessageComponent;
  if (typeof UserMessageComponent !== "function") {
    throw new Error("Firstmate Calm requires Pi UserMessageComponent");
  }
  class CalmOperationalUserMessageComponent extends UserMessageComponent {
    private readonly hasLeadingSpacer: boolean;

    constructor(
      text: UserMessageConstructorArgs[0],
      markdownTheme: UserMessageConstructorArgs[1],
      outputPad: number,
      hasLeadingSpacer: boolean,
    ) {
      super(text, markdownTheme, outputPad);
      this.hasLeadingSpacer = hasLeadingSpacer;
    }

    override render(width: number): string[] {
      if (patch.hidesOperationalInput()) return [];
      const lines = super.render(width);
      return this.hasLeadingSpacer ? ["", ...lines] : lines;
    }
  }

  prototype.addMessageToChat = function (
    message: UserMessageLike,
    options?: AddMessageOptions,
  ): void {
    // Record the provenance of every user message so the assistant-row adapter
    // can bind a routine acknowledgement to a typed operational origin: a user
    // message resets it to genuine, and only a typed operational input marks it
    // operational. A non-user message never touches provenance.
    if (message.role === "user") {
      const textOnly = contentIsTextOnly(message.content);
      const text = textOnly ? this.getUserMessageText(message) : "";
      const operational = textOnly && text.length > 0 && patch.isOperationalInput(text);
      patch.noteUserProvenance(operational);
      if (operational) {
        const component = new CalmOperationalUserMessageComponent(
          text,
          this.getMarkdownThemeWithSettings(),
          this.outputPad,
          this.chatContainer.children.length > 0,
        );
        this.chatContainer.addChild(component);
        if (options?.populateHistory) this.editor.addToHistory?.(text);
        return;
      }
    }

    originalAddMessageToChat.call(this, message, options);
  };

  registry[CALM_OPERATIONAL_USER_LAYOUT_PATCH] = patch;
}
