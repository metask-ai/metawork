// Resolve absolute one-time and fixed-interval inputs.
function wallTimestamp(unixMilliseconds: number, timezone: string): number {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: timezone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hourCycle: "h23",
  }).formatToParts(new Date(unixMilliseconds));
  const number = (name: Intl.DateTimeFormatPartTypes) =>
    Number(parts.find((part) => part.type === name)!.value);
  return Date.UTC(
    number("year"),
    number("month") - 1,
    number("day"),
    number("hour"),
    number("minute"),
    number("second"),
  );
}

function resolveWall(wall: number, timezone: string): number | null {
  let earliest: number | null = null;
  // Sample both sides of the candidate date to include transition offsets.
  for (let day = -2; day <= 2; day++) {
    const sample = wall + day * 86400000;
    const offset = wallTimestamp(sample, timezone) - sample;
    const instant = wall - offset;
    if (
      wallTimestamp(instant, timezone) === wall &&
      (earliest === null || instant < earliest)
    )
      earliest = instant;
  }
  return earliest;
}

export function calendarInstant(text: string, timezone: string): number | null {
  const wall = Date.parse(`${text}:00Z`);
  if (!Number.isFinite(wall)) return null;
  const instant = resolveWall(wall, timezone);
  return instant !== null && instant > 0 && instant <= 253402300799000
    ? Math.floor(instant / 1000)
    : null;
}

export function nextOnceTime(time: string, timezone: string): number | null {
  if (!/^\d{2}:\d{2}$/.test(time)) return null;
  const [hour, minute] = time.split(":").map(Number);
  if (hour > 23 || minute > 59) return null;
  const now = Date.now();
  let today: Date;
  try {
    today = new Date(wallTimestamp(now, timezone));
  } catch (error) {
    if (error instanceof RangeError) return null;
    throw error;
  }
  today.setUTCHours(hour, minute, 0, 0);
  for (let offset = 0; offset < 367; offset++) {
    const candidate = new Date(today);
    candidate.setUTCDate(candidate.getUTCDate() + offset);
    const instant = resolveWall(candidate.getTime(), timezone);
    if (instant !== null && instant > now && instant <= 253402300799000)
      return Math.floor(instant / 1000);
  }
  return null;
}
