import { media } from '@kit.MediaKit';
import { audio } from '@kit.AudioKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import tdbridge, { EncodedVoice } from 'libtdbridge.so';
import { ensureDir } from '../common/Util';

export type PlayerListener = () => void;

// Single app-wide player for voice notes and music, like the official apps:
// starting one track stops the previous one.
export class AudioService {
  private static instance: AudioService | null = null;
  private player: media.AVPlayer | null = null;
  private fd: number = -1;
  private listeners: PlayerListener[] = [];
  private wavCache: Map<string, string> = new Map();
  key: string = '';        // `${chatId}:${msgId}` of the current track
  playing: boolean = false;
  position: number = 0;    // ms
  duration: number = 0;    // ms
  title: string = '';
  speed: number = 1;
  onEnded: (key: string) => void = () => {};

  static get(): AudioService {
    if (!AudioService.instance) {
      AudioService.instance = new AudioService();
    }
    return AudioService.instance;
  }

  on(l: PlayerListener): void {
    this.listeners.push(l);
  }

  off(l: PlayerListener): void {
    this.listeners = this.listeners.filter((x: PlayerListener) => x !== l);
  }

  private changed(): void {
    for (const l of this.listeners) {
      l();
    }
  }

  // Ogg/Opus is decoded to WAV once and cached; other formats play directly.
  private playable(ctx: common.UIAbilityContext, path: string, isOpus: boolean): Promise<string> {
    if (!isOpus) {
      return Promise.resolve(path);
    }
    const cached = this.wavCache.get(path);
    if (cached && fs.accessSync(cached)) {
      return Promise.resolve(cached);
    }
    const out = `${ensureDir(ctx.cacheDir + '/voice')}/${path.replace(/[\/\\:]/g, '_')}.wav`;
    return tdbridge.decodeOpusToWav(path, out).then(() => {
      this.wavCache.set(path, out);
      return out;
    });
  }

  toggle(ctx: common.UIAbilityContext, key: string, path: string, isOpus: boolean, title: string): void {
    if (this.key === key && this.player) {
      if (this.playing) {
        this.player.pause();
      } else {
        this.player.play();
      }
      return;
    }
    this.stop();
    this.key = key;
    this.title = title;
    this.position = 0;
    this.duration = 0;
    this.changed();
    this.playable(ctx, path, isOpus).then((file: string) => this.start(key, file)).catch(() => {
      this.key = '';
      this.changed();
    });
  }

  private start(key: string, file: string): void {
    if (this.key !== key) {
      return;
    }
    media.createAVPlayer().then((p: media.AVPlayer) => {
      if (this.key !== key) {
        p.release();
        return;
      }
      this.player = p;
      p.on('stateChange', (state: string) => {
        if (state === 'initialized') {
          p.prepare();
        } else if (state === 'prepared') {
          this.duration = p.duration;
          p.setSpeed(this.speedEnum());
          p.play();
        } else if (state === 'playing') {
          this.playing = true;
          this.changed();
        } else if (state === 'paused') {
          this.playing = false;
          this.changed();
        } else if (state === 'completed') {
          const ended = this.key;
          this.stop();
          this.onEnded(ended);
        }
      });
      p.on('timeUpdate', (t: number) => {
        this.position = t;
        this.changed();
      });
      p.on('error', () => this.stop());
      this.fd = fs.openSync(file, fs.OpenMode.READ_ONLY).fd;
      p.url = `fd://${this.fd}`;
    });
  }

  // True while a voice note or music track is loaded (playing or paused).
  hasTrack(): boolean {
    return this.player !== null;
  }

  // Pauses or resumes the current track.
  togglePause(): void {
    if (!this.player) {
      return;
    }
    if (this.playing) {
      this.player.pause();
    } else {
      this.player.play();
    }
  }

  seek(fraction: number): void {
    if (this.player && this.duration > 0) {
      this.player.seek(Math.floor(this.duration * fraction));
    }
  }

  cycleSpeed(): void {
    this.speed = this.speed === 1 ? 1.5 : (this.speed === 1.5 ? 2 : 1);
    this.player?.setSpeed(this.speedEnum());
    this.changed();
  }

  private speedEnum(): media.PlaybackSpeed {
    return this.speed === 2 ? media.PlaybackSpeed.SPEED_FORWARD_2_00_X :
      (this.speed === 1.5 ? media.PlaybackSpeed.SPEED_FORWARD_1_50_X : media.PlaybackSpeed.SPEED_FORWARD_1_00_X);
  }

  stop(): void {
    if (this.player) {
      this.player.release();
      this.player = null;
    }
    if (this.fd >= 0) {
      fs.closeSync(this.fd);
      this.fd = -1;
    }
    this.key = '';
    this.playing = false;
    this.position = 0;
    this.changed();
  }
}

// Records 16 kHz mono speech and encodes it to Ogg/Opus natively.
export class VoiceRecorder {
  private capturer: audio.AudioCapturer | null = null;
  path: string = '';
  startedAt: number = 0;

  start(ctx: common.UIAbilityContext): Promise<void> {
    this.path = `${ensureDir(ctx.cacheDir + '/rec')}/${Date.now()}.ogg`;
    const options: audio.AudioCapturerOptions = {
      streamInfo: {
        samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
        channels: audio.AudioChannel.CHANNEL_1,
        sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
        encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
      },
      capturerInfo: { source: audio.SourceType.SOURCE_TYPE_MIC, capturerFlags: 0 }
    };
    if (!tdbridge.encoderStart(this.path, 16000)) {
      return Promise.reject(new Error('encoder init failed'));
    }
    return audio.createAudioCapturer(options).then((c: audio.AudioCapturer) => {
      this.capturer = c;
      c.on('readData', (buf: ArrayBuffer) => tdbridge.encoderWrite(buf));
      this.startedAt = Date.now();
      return c.start();
    });
  }

  // Resolves the encoded file, or null when cancelled / too short.
  stop(cancel: boolean): Promise<EncodedVoice | null> {
    const c = this.capturer;
    this.capturer = null;
    const done = (): EncodedVoice | null => {
      const res: EncodedVoice = tdbridge.encoderStop();
      return cancel || res.duration < 0.5 ? null : res;
    };
    if (!c) {
      return Promise.resolve(done());
    }
    return c.stop().then((): Promise<void> => c.release())
      .then((): EncodedVoice | null => done())
      .catch((): EncodedVoice | null => done());
  }
}
