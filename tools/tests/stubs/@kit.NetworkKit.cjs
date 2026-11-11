// Test stand-in for @kit.NetworkKit: requests go to globalThis.httpHandler.
exports.connection = {};
exports.http = {
  RequestMethod: { POST: 'POST' },
  HttpDataType: { STRING: 0 },
  createHttp: () => ({
    request: (url, options) => Promise.resolve().then(() => globalThis.httpHandler(url, options)),
    destroy: () => {}
  })
};
