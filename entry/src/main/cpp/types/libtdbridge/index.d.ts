// Creates a TDLib client and returns its id.
export const createClient: () => number;
// Sends a JSON-serialized TDLib request.
export const send: (clientId: number, request: string) => void;
// Synchronously executes a TDLib request that can be executed synchronously.
export const execute: (request: string) => string;
// Starts the receive thread. The callback gets batches of JSON-serialized
// updates and responses, in arrival order. Calling again replaces the callback.
export const startReceive: (onBatch: (batch: string[]) => void) => void;
export interface QrMatrix {
  size: number;
  modules: string; // row-major, '1' = dark module
}
// Encodes text as a QR code (used for QR login links).
export const qrMatrix: (text: string) => QrMatrix;

// Decodes an Ogg/Opus file to 16-bit WAV; resolves the duration in seconds.
export const decodeOpusToWav: (inPath: string, outPath: string) => Promise<number>;
// Inflates a gzip file (TGS sticker) and resolves its content as a string.
export const gunzipToString: (path: string) => Promise<string>;

export interface EncodedVoice {
  duration: number; // seconds
  waveform: string; // base64 of Telegram's packed 5-bit waveform
}
// Ogg/Opus voice recorder fed with 16-bit mono PCM chunks.
export const encoderStart: (path: string, sampleRate: number) => boolean;
export const encoderWrite: (pcm: ArrayBuffer) => void;
export const encoderStop: () => EncodedVoice;
