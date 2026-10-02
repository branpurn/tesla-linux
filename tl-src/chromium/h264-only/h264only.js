// Tesla Linux — make web video players choose H.264. (Original script; same idea as the h264ify extension.)
// The Pi 4 has a V4L2 H.264 decoder (/dev/video10) but NO VP9/AV1 hardware
// decoder; those codecs fall back to slow software decode. Players choose the
// codec with MediaSource.isTypeSupported / canPlayType / MediaCapabilities, so
// we answer "unsupported" for VP8/VP9/AV1 and let them fall back to avc1.
(function () {
  'use strict';
  var BLOCKED = /(vp0?8|vp0?9|vp09|av0?1|av01)/i;
  function blocked(type) { return typeof type === 'string' && BLOCKED.test(type); }

  if (window.MediaSource && MediaSource.isTypeSupported) {
    var origIts = MediaSource.isTypeSupported.bind(MediaSource);
    MediaSource.isTypeSupported = function (type) {
      return blocked(type) ? false : origIts(type);
    };
  }
  if (window.ManagedMediaSource && ManagedMediaSource.isTypeSupported) {
    var origMits = ManagedMediaSource.isTypeSupported.bind(ManagedMediaSource);
    ManagedMediaSource.isTypeSupported = function (type) {
      return blocked(type) ? false : origMits(type);
    };
  }
  var origCpt = HTMLMediaElement.prototype.canPlayType;
  HTMLMediaElement.prototype.canPlayType = function (type) {
    return blocked(type) ? '' : origCpt.call(this, type);
  };
  if (navigator.mediaCapabilities && navigator.mediaCapabilities.decodingInfo) {
    var origDi = navigator.mediaCapabilities.decodingInfo.bind(navigator.mediaCapabilities);
    navigator.mediaCapabilities.decodingInfo = function (config) {
      var ct = config && config.video && config.video.contentType;
      if (blocked(ct)) {
        return Promise.resolve({
          supported: false, smooth: false, powerEfficient: false,
          keySystemAccess: null, configuration: config
        });
      }
      return origDi(config);
    };
  }
})();
