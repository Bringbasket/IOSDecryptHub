// IOSDecryptHub WKWebView document-start probe.
// The Objective-C host wraps this file in a function and provides ALLOW, DENY and NAME.
// Keep this file dependency-free: it runs inside arbitrary iOS 14+ page worlds.

if (!window.__iosDecryptHubProbeV2) {
  try {
    Object.defineProperty(window, '__iosDecryptHubProbeV2', { value: true, configurable: false });
  } catch (_) {
    window.__iosDecryptHubProbeV2 = true;
  }

  var DH_MAX_BODY = 64 * 1024;
  var dhCounter = 0;

  function dhId(prefix) {
    dhCounter += 1;
    return (prefix || 'dh') + '-' + Date.now().toString(36) + '-' + dhCounter.toString(36);
  }

  function dhClip(value, limit) {
    try {
      if (value == null) return null;
      var text = typeof value === 'string' ? value : JSON.stringify(value);
      if (typeof text !== 'string') text = String(value);
      return text.length > limit ? text.slice(0, limit) : text;
    } catch (_) {
      try { return String(value).slice(0, limit); } catch (_) { return null; }
    }
  }

  function dhHeaders(headers) {
    var out = {};
    try {
      if (!headers) return out;
      if (typeof headers.forEach === 'function') {
        headers.forEach(function (value, key) { out[String(key)] = String(value); });
      } else if (Array.isArray(headers)) {
        headers.forEach(function (pair) {
          if (pair && pair.length >= 2) out[String(pair[0])] = String(pair[1]);
        });
      } else {
        Object.keys(headers).forEach(function (key) { out[key] = String(headers[key]); });
      }
    } catch (_) {}
    return out;
  }

  function dhFullURL(url) {
    try { return new URL(String(url || ''), location.href).href; }
    catch (_) { return String(url || ''); }
  }

  function dhShouldReport(url) {
    try {
      var host = new URL(url || location.href, location.href).hostname.toLowerCase();
      var i;
      for (i = 0; i < DENY.length; i++) {
        var denied = String(DENY[i]).toLowerCase();
        if (host === denied || host.slice(-(denied.length + 1)) === '.' + denied) return false;
      }
      if (ALLOW.length) {
        for (i = 0; i < ALLOW.length; i++) {
          var allowed = String(ALLOW[i]).toLowerCase();
          if (host === allowed || host.slice(-(allowed.length + 1)) === '.' + allowed) return true;
        }
        return false;
      }
      return true;
    } catch (_) {
      return true;
    }
  }

  function dhPost(method, params, url) {
    try {
      var absoluteURL = dhFullURL(url || (params && params.url) || location.href);
      if (!dhShouldReport(absoluteURL)) return;
      window.webkit.messageHandlers[NAME].postMessage({
        schema: 'iosdecrypthub.cdp.v1',
        source: 'js',
        method: method,
        kind: method,
        ts: Date.now(),
        url: absoluteURL,
        params: params || {}
      });
    } catch (_) {}
  }

  function dhBytesToBase64(bytes) {
    var parts = [];
    var chunk = 0x8000;
    for (var offset = 0; offset < bytes.length; offset += chunk) {
      var slice = bytes.subarray(offset, Math.min(offset + chunk, bytes.length));
      parts.push(String.fromCharCode.apply(null, slice));
    }
    return btoa(parts.join(''));
  }

  function dhBinary(bytes, extra) {
    var originalLength = bytes.byteLength || bytes.length || 0;
    var take = Math.min(originalLength, DH_MAX_BODY);
    var view = bytes instanceof Uint8Array
      ? bytes.subarray(0, take)
      : new Uint8Array(bytes.buffer || bytes, bytes.byteOffset || 0, take);
    var out = {
      kind: 'binary',
      length: originalLength,
      capturedLength: take,
      truncated: originalLength > take,
      base64: dhBytesToBase64(view)
    };
    if (extra) Object.keys(extra).forEach(function (key) { out[key] = extra[key]; });
    return out;
  }

  async function dhSerializeBody(body) {
    try {
      if (body == null) return null;
      if (typeof body === 'string') {
        return { kind: 'text', length: body.length, text: dhClip(body, DH_MAX_BODY), truncated: body.length > DH_MAX_BODY };
      }
      if (typeof URLSearchParams !== 'undefined' && body instanceof URLSearchParams) {
        var query = body.toString();
        return { kind: 'urlencoded', length: query.length, text: dhClip(query, DH_MAX_BODY), truncated: query.length > DH_MAX_BODY };
      }
      if (typeof FormData !== 'undefined' && body instanceof FormData) {
        var rawEntries = [];
        if (typeof body.forEach === 'function') {
          body.forEach(function (value, key) { rawEntries.push([String(key), value]); });
        } else if (typeof body.entries === 'function') {
          var iterator = body.entries();
          var item;
          while (!(item = iterator.next()).done) rawEntries.push(item.value);
        }
        var entries = [];
        var total = 0;
        for (var i = 0; i < rawEntries.length; i++) {
          var key = rawEntries[i][0];
          var value = rawEntries[i][1];
          if (typeof value === 'string') {
            total += value.length;
            entries.push({ name: key, value: dhClip(value, DH_MAX_BODY) });
          } else {
            var encoded = await dhSerializeBody(value);
            total += encoded && encoded.length ? encoded.length : 0;
            entries.push({ name: key, value: encoded });
          }
        }
        return { kind: 'formdata', length: total, entries: entries };
      }
      if (typeof Blob !== 'undefined' && body instanceof Blob) {
        var blobBuffer = await body.slice(0, DH_MAX_BODY).arrayBuffer();
        var blobResult = dhBinary(new Uint8Array(blobBuffer), {
          kind: typeof File !== 'undefined' && body instanceof File ? 'file' : 'blob',
          mimeType: body.type || '',
          name: body.name || '',
          lastModified: body.lastModified || 0
        });
        blobResult.length = body.size;
        blobResult.capturedLength = blobBuffer.byteLength;
        blobResult.truncated = body.size > blobBuffer.byteLength;
        return blobResult;
      }
      if (typeof ArrayBuffer !== 'undefined' && body instanceof ArrayBuffer) {
        return dhBinary(new Uint8Array(body), { kind: 'arraybuffer' });
      }
      if (typeof ArrayBuffer !== 'undefined' && ArrayBuffer.isView && ArrayBuffer.isView(body)) {
        return dhBinary(new Uint8Array(body.buffer, body.byteOffset, body.byteLength), {
          kind: body.constructor && body.constructor.name ? body.constructor.name : 'typedarray'
        });
      }
      if (typeof Document !== 'undefined' && body instanceof Document) {
        var html = body.documentElement ? body.documentElement.outerHTML : String(body);
        return { kind: 'document', length: html.length, text: dhClip(html, DH_MAX_BODY), truncated: html.length > DH_MAX_BODY };
      }
      var json = JSON.stringify(body);
      if (typeof json === 'string') {
        return { kind: 'json', length: json.length, text: dhClip(json, DH_MAX_BODY), truncated: json.length > DH_MAX_BODY };
      }
      var description = String(body);
      return { kind: 'text', length: description.length, text: dhClip(description, DH_MAX_BODY), truncated: description.length > DH_MAX_BODY };
    } catch (error) {
      return { kind: 'unavailable', error: String(error && error.message || error) };
    }
  }

  function dhBodyPayload(body, field) {
    var out = {};
    if (!body) return out;
    var value = '';
    if (typeof body.text === 'string') value = body.text;
    else if (typeof body.base64 === 'string') value = body.base64;
    else {
      try { value = JSON.stringify(body); } catch (_) { value = String(body); }
    }
    out[field] = value;
    out.base64Encoded = typeof body.base64 === 'string';
    var info = {};
    Object.keys(body).forEach(function (key) {
      if (key !== 'text' && key !== 'base64') info[key] = body[key];
    });
    out.bodyInfo = info;
    return out;
  }

  async function dhSerializeResponse(response) {
    var clone = response.clone();
    var declared = 0;
    try { declared = parseInt(response.headers.get('content-length') || '0', 10) || 0; } catch (_) {}
    try {
      if (clone.body && typeof clone.body.getReader === 'function') {
        var reader = clone.body.getReader();
        var chunks = [];
        var captured = 0;
        var observed = 0;
        var truncated = false;
        while (true) {
          var part = await reader.read();
          if (part.done) break;
          var value = part.value instanceof Uint8Array ? part.value : new Uint8Array(part.value || 0);
          observed += value.byteLength;
          if (captured < DH_MAX_BODY) {
            var take = Math.min(value.byteLength, DH_MAX_BODY - captured);
            if (take) chunks.push(value.subarray(0, take));
            captured += take;
          }
          if (observed >= DH_MAX_BODY) {
            truncated = true;
            try { await reader.cancel(); } catch (_) {}
            break;
          }
        }
        var joined = new Uint8Array(captured);
        var offset = 0;
        chunks.forEach(function (chunk) { joined.set(chunk, offset); offset += chunk.byteLength; });
        var result = dhBinary(joined, { kind: 'response' });
        result.length = declared || observed;
        result.capturedLength = captured;
        result.truncated = truncated || (declared > captured);
        return result;
      }
    } catch (_) {}
    if (declared > 1024 * 1024) {
      return { kind: 'unavailable', length: declared, capturedLength: 0, truncated: true, error: 'response too large for non-streaming fallback' };
    }
    return dhSerializeBody(await clone.arrayBuffer());
  }

  function dhResponseHeaders(xhr) {
    var out = {};
    try {
      String(xhr.getAllResponseHeaders() || '').split(/\r?\n/).forEach(function (line) {
        var idx = line.indexOf(':');
        if (idx > 0) out[line.slice(0, idx).trim()] = line.slice(idx + 1).trim();
      });
    } catch (_) {}
    return out;
  }

  // fetch / Request
  var dhOriginalFetch = window.fetch;
  if (dhOriginalFetch) {
    window.fetch = function (input, init) {
      var requestId = dhId('fetch');
      var url = typeof input === 'string' || (typeof URL !== 'undefined' && input instanceof URL)
        ? String(input) : (input && input.url) || '';
      var method = (init && init.method) || (input && input.method) || 'GET';
      var headers = dhHeaders(input && input.headers);
      var initHeaders = dhHeaders(init && init.headers);
      Object.keys(initHeaders).forEach(function (key) { headers[key] = initHeaders[key]; });
      var started = Date.now();
      var bodyPromise;
      if (init && Object.prototype.hasOwnProperty.call(init, 'body')) {
        bodyPromise = dhSerializeBody(init.body);
      } else if (typeof Request !== 'undefined' && input instanceof Request && input.method !== 'GET' && input.method !== 'HEAD') {
        try { bodyPromise = input.clone().arrayBuffer().then(dhSerializeBody); }
        catch (_) { bodyPromise = Promise.resolve(null); }
      } else {
        bodyPromise = Promise.resolve(null);
      }
      // Resolve promised Request bodies before serialization.
      bodyPromise = Promise.resolve(bodyPromise).then(function (value) {
        return value && typeof value.then === 'function' ? value.then(dhSerializeBody) : value;
      });
      bodyPromise.then(function (body) {
        dhPost('Network.requestWillBeSent', {
          requestId: requestId,
          type: 'Fetch',
          timestamp: started / 1000,
          request: { url: dhFullURL(url), method: String(method), headers: headers, hasPostData: !!body }
        }, url);
        if (body) {
          dhPost('Network.requestPostData', Object.assign({ requestId: requestId }, dhBodyPayload(body, 'postData')), url);
        }
      });

      var result;
      try { result = dhOriginalFetch.apply(this, arguments); }
      catch (error) {
        dhPost('Network.loadingFailed', { requestId: requestId, type: 'Fetch', timestamp: Date.now() / 1000, errorText: String(error) }, url);
        throw error;
      }
      return result.then(function (response) {
        var responseHeaders = dhHeaders(response.headers);
        dhPost('Network.responseReceived', {
          requestId: requestId,
          type: 'Fetch',
          timestamp: Date.now() / 1000,
          response: {
            url: response.url || dhFullURL(url),
            status: response.status,
            statusText: response.statusText || '',
            headers: responseHeaders,
            mimeType: responseHeaders['content-type'] || responseHeaders['Content-Type'] || ''
          }
        }, response.url || url);
        try {
          dhSerializeResponse(response).then(function (body) {
            dhPost('Network.loadingFinished', {
              requestId: requestId,
              timestamp: Date.now() / 1000,
              encodedDataLength: body && body.length || 0
            }, response.url || url);
            dhPost('Network.responseBody', Object.assign({ requestId: requestId }, dhBodyPayload(body, 'body')), response.url || url);
          }).catch(function (error) {
            dhPost('Network.loadingFinished', {
              requestId: requestId,
              timestamp: Date.now() / 1000,
              encodedDataLength: 0,
              bodyError: String(error && error.message || error)
            }, response.url || url);
          });
        } catch (_) {}
        return response;
      }, function (error) {
        dhPost('Network.loadingFailed', {
          requestId: requestId,
          type: 'Fetch',
          timestamp: Date.now() / 1000,
          errorText: String(error && error.message || error)
        }, url);
        throw error;
      });
    };
  }

  // XMLHttpRequest
  if (window.XMLHttpRequest && XMLHttpRequest.prototype) {
    var dhXHROpen = XMLHttpRequest.prototype.open;
    var dhXHRSend = XMLHttpRequest.prototype.send;
    var dhXHRSetHeader = XMLHttpRequest.prototype.setRequestHeader;
    XMLHttpRequest.prototype.open = function (method, url) {
      this.__dh = { requestId: dhId('xhr'), method: String(method || 'GET'), url: dhFullURL(url), headers: {}, started: 0 };
      return dhXHROpen.apply(this, arguments);
    };
    XMLHttpRequest.prototype.setRequestHeader = function (key, value) {
      try { if (this.__dh) this.__dh.headers[String(key)] = String(value); } catch (_) {}
      return dhXHRSetHeader.apply(this, arguments);
    };
    XMLHttpRequest.prototype.send = function (body) {
      var xhr = this;
      var state = xhr.__dh || { requestId: dhId('xhr'), method: 'GET', url: location.href, headers: {} };
      state.started = Date.now();
      Promise.resolve(dhSerializeBody(body)).then(function (serialized) {
        dhPost('Network.requestWillBeSent', {
          requestId: state.requestId,
          type: 'XHR',
          timestamp: state.started / 1000,
          request: { url: state.url, method: state.method, headers: state.headers || {}, hasPostData: !!serialized }
        }, state.url);
        if (serialized) {
          dhPost('Network.requestPostData', Object.assign({ requestId: state.requestId }, dhBodyPayload(serialized, 'postData')), state.url);
        }
      });
      xhr.addEventListener('loadend', function () {
        var responseHeaders = dhResponseHeaders(xhr);
        dhPost('Network.responseReceived', {
          requestId: state.requestId,
          type: 'XHR',
          timestamp: Date.now() / 1000,
          response: {
            url: state.url,
            status: xhr.status,
            statusText: xhr.statusText || '',
            headers: responseHeaders,
            mimeType: xhr.getResponseHeader('Content-Type') || ''
          }
        }, state.url);
        var responseValue = null;
        try { responseValue = xhr.responseType === '' || xhr.responseType === 'text' ? xhr.responseText : xhr.response; }
        catch (_) {}
        Promise.resolve(dhSerializeBody(responseValue)).then(function (serialized) {
          dhPost(xhr.status === 0 ? 'Network.loadingFailed' : 'Network.loadingFinished', {
            requestId: state.requestId,
            type: 'XHR',
            timestamp: Date.now() / 1000,
            encodedDataLength: serialized && serialized.length || 0,
            errorText: xhr.status === 0 ? 'XHR network error' : undefined
          }, state.url);
          if (xhr.status !== 0) {
            dhPost('Network.responseBody', Object.assign({ requestId: state.requestId }, dhBodyPayload(serialized, 'body')), state.url);
          }
        });
      });
      return dhXHRSend.apply(this, arguments);
    };
  }

  // WebSocket frames
  var dhOriginalWebSocket = window.WebSocket;
  if (dhOriginalWebSocket) {
    var DHWebSocket = function (url, protocols) {
      var ws = protocols === undefined ? new dhOriginalWebSocket(url) : new dhOriginalWebSocket(url, protocols);
      var requestId = dhId('ws');
      dhPost('Network.webSocketCreated', { requestId: requestId, url: dhFullURL(url) }, url);
      ws.addEventListener('open', function () {
        dhPost('Network.webSocketHandshakeResponseReceived', {
          requestId: requestId,
          timestamp: Date.now() / 1000,
          response: { status: 101, statusText: 'Switching Protocols', headers: {} }
        }, url);
      });
      ws.addEventListener('message', function (event) {
        Promise.resolve(dhSerializeBody(event.data)).then(function (payload) {
          dhPost('Network.webSocketFrameReceived', {
            requestId: requestId,
            timestamp: Date.now() / 1000,
            response: payload
          }, url);
        });
      });
      var originalSend = ws.send;
      ws.send = function (data) {
        Promise.resolve(dhSerializeBody(data)).then(function (payload) {
          dhPost('Network.webSocketFrameSent', {
            requestId: requestId,
            timestamp: Date.now() / 1000,
            response: payload
          }, url);
        });
        return originalSend.apply(ws, arguments);
      };
      ws.addEventListener('close', function () {
        dhPost('Network.webSocketClosed', { requestId: requestId, timestamp: Date.now() / 1000 }, url);
      });
      ws.addEventListener('error', function () {
        dhPost('Network.webSocketFrameError', { requestId: requestId, timestamp: Date.now() / 1000, errorMessage: 'WebSocket error' }, url);
      });
      return ws;
    };
    DHWebSocket.prototype = dhOriginalWebSocket.prototype;
    ['CONNECTING', 'OPEN', 'CLOSING', 'CLOSED'].forEach(function (key) {
      try { DHWebSocket[key] = dhOriginalWebSocket[key]; } catch (_) {}
    });
    window.WebSocket = DHWebSocket;
  }

  // EventSource and sendBeacon
  if (window.EventSource) {
    var dhOriginalEventSource = window.EventSource;
    var DHEventSource = function (url, config) {
      var stream = config === undefined ? new dhOriginalEventSource(url) : new dhOriginalEventSource(url, config);
      var requestId = dhId('sse');
      dhPost('Network.eventSourceCreated', { requestId: requestId, url: dhFullURL(url) }, url);
      stream.addEventListener('message', function (event) {
        dhPost('Network.eventSourceMessageReceived', { requestId: requestId, timestamp: Date.now() / 1000, data: dhClip(event.data, DH_MAX_BODY) }, url);
      });
      return stream;
    };
    DHEventSource.prototype = dhOriginalEventSource.prototype;
    window.EventSource = DHEventSource;
  }
  if (navigator.sendBeacon) {
    var dhOriginalBeacon = navigator.sendBeacon.bind(navigator);
    navigator.sendBeacon = function (url, data) {
      var requestId = dhId('beacon');
      Promise.resolve(dhSerializeBody(data)).then(function (serialized) {
        dhPost('Network.requestWillBeSent', {
          requestId: requestId,
          type: 'Beacon',
          timestamp: Date.now() / 1000,
          request: { url: dhFullURL(url), method: 'POST', headers: {}, hasPostData: !!serialized }
        }, url);
        if (serialized) dhPost('Network.requestPostData', Object.assign({ requestId: requestId }, dhBodyPayload(serialized, 'postData')), url);
      });
      var accepted = dhOriginalBeacon(url, data);
      dhPost('Network.loadingFinished', { requestId: requestId, timestamp: Date.now() / 1000, accepted: !!accepted }, url);
      return accepted;
    };
  }

  // Static resources are invisible to fetch/XHR wrappers. ResourceTiming supplies a useful
  // fallback; Remote Inspector remains the authoritative source when connected.
  try {
    if (window.PerformanceObserver) {
      var resourceObserver = new PerformanceObserver(function (list) {
        list.getEntries().forEach(function (entry) {
          if (entry.entryType !== 'resource') return;
          dhPost('Network.resourceObserved', {
            requestId: dhId('resource'),
            type: entry.initiatorType || 'Other',
            timestamp: (performance.timeOrigin + entry.startTime) / 1000,
            request: { url: entry.name, method: 'GET', headers: {} },
            timing: {
              duration: entry.duration,
              transferSize: entry.transferSize || 0,
              encodedBodySize: entry.encodedBodySize || 0,
              decodedBodySize: entry.decodedBodySize || 0,
              nextHopProtocol: entry.nextHopProtocol || ''
            }
          }, entry.name);
        });
      });
      resourceObserver.observe({ entryTypes: ['resource'] });
    }
  } catch (_) {}

  // Preserve the pre-existing behaviour-analysis probes.
  try {
    if (window.Storage && Storage.prototype && !Storage.prototype.__dh) {
      Storage.prototype.__dh = true;
      ['setItem', 'removeItem', 'clear'].forEach(function (method) {
        var original = Storage.prototype[method];
        if (!original) return;
        Storage.prototype[method] = function () {
          var storage = this === window.localStorage ? 'localStorage' : 'sessionStorage';
          dhPost('Storage.' + method, { storage: storage, key: arguments[0] == null ? '' : String(arguments[0]), value: arguments[1] == null ? '' : dhClip(arguments[1], DH_MAX_BODY) }, location.href);
          return original.apply(this, arguments);
        };
      });
    }
  } catch (_) {}
  ['log', 'info', 'warn', 'error'].forEach(function (level) {
    try {
      var original = console[level];
      if (!original) return;
      console[level] = function () {
        var args = [];
        for (var i = 0; i < arguments.length; i++) args.push(dhClip(arguments[i], DH_MAX_BODY));
        dhPost('Runtime.consoleAPICalled', { type: level, args: args, timestamp: Date.now() }, location.href);
        return original.apply(console, arguments);
      };
    } catch (_) {}
  });
  try {
    if (window.crypto && crypto.subtle) {
      ['digest', 'encrypt', 'decrypt', 'sign', 'verify', 'deriveBits', 'importKey', 'exportKey'].forEach(function (method) {
        var original = crypto.subtle[method];
        if (!original) return;
        try {
          crypto.subtle[method] = function () {
            var algorithm = arguments[0];
            dhPost('Crypto.' + method, { algorithm: String(algorithm && (algorithm.name || algorithm) || ''), argc: arguments.length }, location.href);
            return original.apply(crypto.subtle, arguments);
          };
        } catch (_) {}
      });
    }
  } catch (_) {}
}
