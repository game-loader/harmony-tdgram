import tdbridge, { QrMatrix } from 'libtdbridge.so';

// Draws a QR code with Canvas from the module matrix computed natively.
@Component
export struct QrView {
  @Prop @Watch('redraw') text: string = '';
  @Prop side: number = 240;
  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private ready: boolean = false;

  redraw(): void {
    if (!this.ready || !this.text) {
      return;
    }
    const qr: QrMatrix = tdbridge.qrMatrix(this.text);
    const quiet = 4; // standard quiet zone, in modules
    const cell = this.side / (qr.size + quiet * 2);
    this.ctx.fillStyle = '#FFFFFF';
    this.ctx.fillRect(0, 0, this.side, this.side);
    this.ctx.fillStyle = '#000000';
    for (let y = 0; y < qr.size; y++) {
      for (let x = 0; x < qr.size; x++) {
        if (qr.modules.charAt(y * qr.size + x) === '1') {
          // Overdraw by a fraction to avoid hairline gaps between cells.
          this.ctx.fillRect((x + quiet) * cell, (y + quiet) * cell, cell + 0.5, cell + 0.5);
        }
      }
    }
  }

  build() {
    Canvas(this.ctx)
      .width(this.side)
      .height(this.side)
      .onReady(() => {
        this.ready = true;
        this.redraw();
      })
  }
}
