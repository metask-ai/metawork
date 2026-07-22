const dragThresholdSquared = 16;

type PendingPointer = {
  id: number;
  x: number;
  y: number;
};

export class WindowTitlebarGesture {
  private pending: PendingPointer | null = null;

  begin(pointerId: number, x: number, y: number) {
    this.pending = { id: pointerId, x, y };
  }

  move(pointerId: number, x: number, y: number, buttons: number): 1 | null {
    const pending = this.pending;
    if (!pending || pending.id !== pointerId) return null;
    if ((buttons & 1) === 0) {
      this.pending = null;
      return null;
    }
    const deltaX = x - pending.x;
    const deltaY = y - pending.y;
    if (deltaX * deltaX + deltaY * deltaY < dragThresholdSquared) return null;
    this.pending = null;
    return 1;
  }

  end(pointerId: number) {
    if (this.pending?.id === pointerId) this.pending = null;
  }

  cancel(pointerId: number) {
    if (this.pending?.id === pointerId) this.pending = null;
  }
}
