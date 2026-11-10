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
