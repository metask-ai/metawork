import { useEffect, useMemo, useRef } from "react";

import type { SkillCatalogView } from "../../bridge/contracts.ts";
import { Icon } from "../../components/ui/Icon.tsx";
import { useI18n, type MessageId } from "../../i18n/context.ts";

type Skill = SkillCatalogView["skills"][number];
type CatalogIssue = SkillCatalogView["issues"][number];

const issueMessageIds: Record<CatalogIssue["code"], MessageId> = {
  invalid_definition: "skills.issue.invalid_definition",
  source_conflict: "skills.issue.source_conflict",
  invalid_resource: "skills.issue.invalid_resource",
  invalid_invocation_name: "skills.issue.invalid_invocation_name",
};

export function filterSkills(skills: Skill[], query: string): Skill[] {
  const needle = query.trim().toLocaleLowerCase();
  if (!needle) return skills;
  return skills.filter((skill) =>
    [
      skill.invocationName,
      skill.displayName,
      skill.description,
      ...skill.argumentNames,
    ].some((value) => value.toLocaleLowerCase().includes(needle)),
  );
}

function SkillRow({ skill }: { skill: Skill }) {
  const { t } = useI18n();
  const hasDistinctDisplayName =
    skill.displayName.trim().length > 0 &&
    skill.displayName !== skill.invocationName;
  return (
    <li className="skills-row">
      <span className="skills-slash" aria-hidden="true">
        /
      </span>
      <div className="skills-row-copy">
        <div className="skills-row-heading">
          <code>{skill.invocationName}</code>
          {hasDistinctDisplayName && <strong>{skill.displayName}</strong>}
        </div>
        {skill.description && <p>{skill.description}</p>}
        <small>
          {skill.argumentNames.length === 0
            ? t("skills.no_arguments")
            : t("skills.arguments", {
                arguments: skill.argumentNames.join(" · "),
              })}
        </small>
      </div>
    </li>
  );
}

function CatalogIssues({ issues }: { issues: CatalogIssue[] }) {
  const { t } = useI18n();
  if (issues.length === 0) return null;
  return (
    <section
      className="skills-issues"
      aria-labelledby="skills-issues-title"
      role="status"
    >
      <h2 id="skills-issues-title">
        {t("skills.issue_count", { count: issues.length })}
      </h2>
      <ul>
        {issues.map((issue, index) => (
          <li key={`${issue.code}:${issue.invocationName ?? ""}:${index}`}>
            {issue.invocationName && <code>{issue.invocationName}</code>}
            <span>{t(issueMessageIds[issue.code])}</span>
          </li>
        ))}
      </ul>
    </section>
  );
}

export function SkillsPage({
  catalog,
  query,
  refreshing,
  disabled,
  onQuery,
  onRefresh,
}: {
  catalog: SkillCatalogView;
  query: string;
  refreshing: boolean;
  disabled: boolean;
  onQuery: (query: string) => void;
  onRefresh: () => void;
}) {
  const { t } = useI18n();
  const title = useRef<HTMLHeadingElement>(null);
  const filteredSkills = useMemo(
    () => filterSkills(catalog.skills, query),
    [catalog.skills, query],
  );
  const catalogUsable =
    !catalog.redacted &&
    (catalog.availability === "ready" || catalog.availability === "degraded");
  const initialLoading =
    !catalog.redacted &&
    (catalog.availability === "uninitialized" ||
      catalog.availability === "loading") &&
    catalog.skills.length === 0;
  const catalogUnavailableWithoutSnapshot =
    catalog.redacted ||
    (catalog.availability === "unavailable" && catalog.skills.length === 0);

  useEffect(() => {
    title.current?.focus();
  }, []);

  return (
    <section className="skills-page" aria-labelledby="skills-title">
      <div className="skills-page-inner">
        <header className="skills-header">
          <div>
            <h1 id="skills-title" ref={title} tabIndex={-1}>
              {t("skills.title")}
            </h1>
            <p>{t("skills.subtitle")}</p>
          </div>
          <button
            className="secondary-button focus-ring skills-refresh"
            disabled={disabled || refreshing}
            onClick={onRefresh}
          >
            <Icon name="refresh" />
            {t(refreshing ? "skills.refreshing" : "skills.refresh")}
          </button>
        </header>

        <>
          <div className="skills-toolbar">
            <label className="skills-search">
              <Icon name="search" />
              <span className="sr-only">{t("skills.search_label")}</span>
              <input
                type="search"
                value={query}
                placeholder={t("skills.search_placeholder")}
                onChange={(event) => onQuery(event.target.value)}
              />
            </label>
            <span className="skills-count" aria-live="polite">
              {catalogUsable
                ? t("skills.available_count", {
                    count: catalog.skills.length,
                  })
                : t(
                    refreshing || initialLoading
                      ? "skills.status_loading"
                      : "skills.status_unavailable",
                  )}
            </span>
          </div>

          {initialLoading ? (
            <div
              className="skills-skeleton"
              aria-label={t("skills.status_loading")}
            >
              {[0, 1, 2].map((item) => (
                <span key={item} />
              ))}
            </div>
          ) : catalogUnavailableWithoutSnapshot ? (
            <div className="skills-state skills-state-compact">
              <span className="skills-state-mark" aria-hidden="true">
                /
              </span>
              <h2>{t("skills.unavailable_title")}</h2>
              <p>{t("skills.unavailable_body")}</p>
            </div>
          ) : catalog.skills.length === 0 ? (
            <div className="skills-state skills-state-compact">
              <span className="skills-state-mark" aria-hidden="true">
                /
              </span>
              <h2>{t("skills.empty_title")}</h2>
              <p>{t("skills.empty_body")}</p>
            </div>
          ) : filteredSkills.length === 0 ? (
            <div className="skills-state skills-state-compact">
              <h2>{t("skills.no_results_title")}</h2>
              <p>{t("skills.no_results_body", { query: query.trim() })}</p>
            </div>
          ) : (
            <ul className="skills-list" aria-label={t("skills.list_label")}>
              {filteredSkills.map((skill) => (
                <SkillRow key={skill.skillId} skill={skill} />
              ))}
            </ul>
          )}

          {catalogUsable && <CatalogIssues issues={catalog.issues} />}
        </>
      </div>
    </section>
  );
}
