import type { ReactNode, RefObject } from "react";

import type { SkillCatalogView } from "../../bridge/contracts.ts";
import { Button } from "../../components/ui/button.tsx";
import { Icon } from "../../components/ui/Icon.tsx";
import { Menu } from "../../components/ui/menu.tsx";
import { useI18n } from "../../i18n/context.ts";
import { resolveSlashCandidates, type SlashCandidate } from "./slash.ts";

export function ComposerAddMenu({
  triggerRef,
  disabled,
  attachmentsEnabled,
  skillText,
  skillCatalog,
  onChooseAttachments,
  workspaceReferenceMenu,
  onRefreshSkills,
  onChooseSkill,
}: {
  triggerRef: RefObject<HTMLButtonElement | null>;
  disabled: boolean;
  attachmentsEnabled: boolean;
  skillText: string | null;
  skillCatalog: SkillCatalogView;
  onChooseAttachments: () => void;
  workspaceReferenceMenu?: ReactNode;
  onRefreshSkills: () => void;
  onChooseSkill: (
    candidate: Extract<SlashCandidate, { kind: "skill" }>,
  ) => void;
}) {
  const { t } = useI18n();
  const skills =
    skillText === null
      ? []
      : resolveSlashCandidates({
          input: { query: "", tail: skillText, explicitSkill: true },
          commands: [],
          catalog: skillCatalog,
        }).filter((candidate) => candidate.kind === "skill");
  const catalogUsable =
    skillCatalog.availability === "ready" ||
    skillCatalog.availability === "degraded";

  return (
    <Menu.Root modal={false}>
      <Menu.Trigger
        ref={triggerRef}
        render={
          <Button
            variant="ghost"
            size="icon"
            className="composer-attachment-add"
          />
        }
        aria-label={t("composer.add")}
        title={t("composer.add")}
        disabled={disabled || (!attachmentsEnabled && skillText === null)}
      >
        <Icon name="plus" />
      </Menu.Trigger>
      <Menu.Portal>
        <Menu.Positioner side="top" align="start">
          <Menu.Popup aria-label={t("composer.add")}>
            {attachmentsEnabled && (
              <Menu.Item onClick={onChooseAttachments}>
                <Icon name="paperclip" />
                {t("attachment.add")}
              </Menu.Item>
            )}
            {attachmentsEnabled && workspaceReferenceMenu}
            <Menu.SubmenuRoot
              onOpenChange={(open) => {
                if (open) onRefreshSkills();
              }}
            >
              <Menu.SubmenuTrigger
                openOnHover={false}
                disabled={skillText === null}
                title={
                  skillText === null
                    ? t("composer.add_skill_with_attachments")
                    : undefined
                }
              >
                <Icon name="skills" />
                <span className="flex-1">{t("composer.add_skill")}</span>
                <Icon name="chevron-right" />
              </Menu.SubmenuTrigger>
              <Menu.Portal>
                <Menu.Positioner side="right" align="start">
                  <Menu.Popup
                    aria-label={t("composer.add_skill")}
                    className="max-h-[min(320px,var(--available-height))] max-w-[min(280px,calc(100vw-32px))] overflow-y-auto"
                  >
                    {skills.length > 0 ? (
                      skills.map((skill) => (
                        <Menu.Item
                          key={skill.key}
                          onClick={() => onChooseSkill(skill)}
                        >
                          <span
                            className="min-w-0 truncate"
                            title={skill.displayName || skill.invocationName}
                          >
                            {skill.displayName || skill.invocationName}
                          </span>
                        </Menu.Item>
                      ))
                    ) : (
                      <Menu.Item disabled>
                        {t(
                          catalogUsable
                            ? "slash.no_skills"
                            : skillCatalog.availability === "loading"
                              ? "slash.skills_loading"
                              : "slash.skills_unavailable",
                        )}
                      </Menu.Item>
                    )}
                  </Menu.Popup>
                </Menu.Positioner>
              </Menu.Portal>
            </Menu.SubmenuRoot>
          </Menu.Popup>
        </Menu.Positioner>
      </Menu.Portal>
    </Menu.Root>
  );
}
