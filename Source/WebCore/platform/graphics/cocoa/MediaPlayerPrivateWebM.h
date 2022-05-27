/*
 * Copyright (C) 2022 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#if PLATFORM(COCOA) && ENABLE(WEBM_EXPERIMENT)

#include "AudioTrackPrivateWebM.h"
#include "HTTPHeaderNames.h"
#include "MediaPlayerPrivate.h"
#include "NotImplemented.h"
#include "PlatformLayer.h"
#include "PlatformMediaResourceLoader.h"
#include "SampleBufferDisplayLayer.h"
#include "SampleMap.h"
#include "TextTrackRepresentation.h"
#include "VideoFrame.h"
#include "VideoLayerManagerObjC.h"
#include "VideoTrackPrivateWebM.h"
#include <wtf/HashMap.h>
#include <wtf/LoggerHelper.h>
#include <wtf/Vector.h>
#include <wtf/WeakPtr.h>

OBJC_CLASS AVSampleBufferAudioRenderer;
OBJC_CLASS AVSampleBufferDisplayLayer;

namespace WebCore {

class WebMResourceClient;

class MediaPlayerPrivateWebM
    : public CanMakeWeakPtr<MediaPlayerPrivateWebM>
    , public MediaPlayerPrivateInterface
    , private LoggerHelper
{
    WTF_MAKE_FAST_ALLOCATED;
public:
    MediaPlayerPrivateWebM(MediaPlayer*);
    ~MediaPlayerPrivateWebM();
    
    static void registerMediaEngine(MediaEngineRegistrar);
    
    void dataReceived(const SharedBuffer&);
    void loadFinished(const FragmentedSharedBuffer&);
    
private:
    void load(const String&) final;
    
#if ENABLE(MEDIA_SOURCE)
    void load(const URL&, const ContentType&, MediaSourcePrivateClient&) final;
#endif
#if ENABLE(MEDIA_STREAM)
    void load(MediaStreamPrivate&) final;
#endif
    
    void cancelLoad() final;
    
    PlatformLayer* platformLayer() const final;
    
    bool supportsPictureInPicture() const override { return true; }
    bool supportsFullscreen() const final { return true; }
    
    void play() final;
    void pause() final;
    
    FloatSize naturalSize() const final { return m_naturalSize; };
    
    bool hasVideo() const final { return m_hasVideo; };
    bool hasAudio() const final { return m_hasAudio; };
    
    void setPageIsVisible(bool) final;
    
    MediaTime currentMediaTime() const final;
    MediaTime durationMediaTime() const final { return m_duration; };
    MediaTime startTime() const final { return MediaTime::zeroTime(); };
    MediaTime initialTime() const final { return MediaTime::zeroTime(); };
    
    void seek(const MediaTime&) final;
    bool seeking() const final { return m_seeking; };
    
    void setRateDouble(double) final;
    double rate() const final { return m_rate; }
    double effectiveRate() const final;
    
    bool paused() const final { return m_paused; };
    
    void setVolume(float) final;
    void setMuted(bool) final;
    
    MediaPlayer::NetworkState networkState() const final { return m_networkState; };
    MediaPlayer::ReadyState readyState() const final { return m_readyState; };
    
    std::unique_ptr<PlatformTimeRanges> seekable() const final;
    MediaTime maxMediaTimeSeekable() const final { return durationMediaTime(); }
    MediaTime minMediaTimeSeekable() const final { return startTime(); }
    std::unique_ptr<PlatformTimeRanges> buffered() const final;
    
    bool didLoadingProgress() const final;
    
    void paint(GraphicsContext&, const FloatRect&) final { };
    
    DestinationColorSpace colorSpace() final { return DestinationColorSpace::SRGB(); };
    
    void setNaturalSize(FloatSize);
    void setHasAudio(bool);
    void setHasVideo(bool);
    void setDuration(const MediaTime&);
    void setDuration(MediaTime&&);
    void setNetworkState(MediaPlayer::NetworkState);
    void setReadyState(MediaPlayer::ReadyState);
    void characteristicsChanged();
    
    bool supportsAcceleratedRendering() const final { return true; };
    
    RetainPtr<PlatformLayer> createVideoFullscreenLayer() final;
    void setVideoFullscreenLayer(PlatformLayer*, Function<void()>&& completionHandler) final;
    void setVideoFullscreenFrame(FloatRect) final;
    
    bool requiresTextTrackRepresentation() const final;
    void setTextTrackRepresentation(TextTrackRepresentation*) final;
    void syncTextTrackBounds() final;
    
    void enqueueSamples();
    void enqueueSamplesForTime(const MediaTime&);
    
    void demuxWebMData(SharedBuffer&);
    
    void ensureLayer();
    void ensureAudioRenderer();
    
    void destroyLayer();
    void destroyAudioRenderer();
    void clearTracks();
    
    const Logger& logger() const final { return m_logger.get(); }
    const char* logClassName() const final { return "MediaPlayerPrivateWebM"; }
    const void* logIdentifier() const final { return reinterpret_cast<const void*>(m_logIdentifier); }
    WTFLogChannel& logChannel() const final;
    
    friend class MediaPlayerFactoryWebM;
    static bool isAvailable();
    static void getSupportedTypes(HashSet<String, ASCIICaseInsensitiveHash>&);
    static MediaPlayer::SupportsType supportsType(const MediaEngineSupportParameters&);
    
    MediaPlayer* m_player;
    RetainPtr<AVSampleBufferRenderSynchronizer> m_synchronizer;
    RetainPtr<id> m_durationObserver;
    WeakPtr<WebMResourceClient> m_resourceClient;
    
    Vector<RefPtr<VideoTrackPrivateWebM>> m_videoTracks;
    Vector<RefPtr<AudioTrackPrivateWebM>> m_audioTracks;
    
    RetainPtr<AVSampleBufferDisplayLayer> m_displayLayer;
    RetainPtr<AVSampleBufferAudioRenderer> m_audioRenderer;
    
    SampleMap m_videoSamples;
    SampleMap m_audioSamples;
    
    MediaPlayer::NetworkState m_networkState;
    MediaPlayer::ReadyState m_readyState;
    
    Ref<const Logger> m_logger;
    const void* m_logIdentifier;
    std::unique_ptr<VideoLayerManagerObjC> m_videoLayerManager;
    
    FloatSize m_naturalSize;
    bool m_hasAudio;
    bool m_hasVideo;
    MediaTime m_currentTime;
    MediaTime m_duration;
    double m_rate;
    bool m_seeking;
    bool m_paused;
    bool m_visible;
};

} // namespace WebCore

#endif // PLATFORM(COCOA)
