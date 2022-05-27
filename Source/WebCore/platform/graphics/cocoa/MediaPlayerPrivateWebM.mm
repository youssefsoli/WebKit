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

#import "config.h"
#import "MediaPlayerPrivateWebM.h"

#if PLATFORM(COCOA) && ENABLE(WEBM_EXPERIMENT)

#import "FloatSize.h"
#import "HTTPHeaderNames.h"
#import "Logging.h"
#import "MediaPlayer.h"
#import "MediaSampleAVFObjC.h"
#import "ResourceError.h"
#import "ResourceRequest.h"
#import "ResourceResponse.h"
#import "SecurityOrigin.h"
#import "SourceBufferParserWebM.h"
#import "VideoFrameCV.h"
#import "VideoTrackPrivateWebM.h"
#import <pal/avfoundation/MediaTimeAVFoundation.h>
#import <pal/spi/cocoa/AVFoundationSPI.h>
#import <pal/cf/CoreMediaSoftLink.h>
#import <pal/cocoa/AVFoundationSoftLink.h>

namespace WebCore {

class WebMResourceClient final : public PlatformMediaResourceClient, public CanMakeWeakPtr<WebMResourceClient> {
WTF_MAKE_FAST_ALLOCATED;
public:
    static WeakPtr<WebMResourceClient> create(MediaPlayerPrivateWebM&, PlatformMediaResourceLoader&, ResourceRequest&&);
    ~WebMResourceClient() { stop(); }
    
    void stop();
    
private:
    WebMResourceClient(MediaPlayerPrivateWebM&, Ref<PlatformMediaResource>&&);
    
    void dataReceived(PlatformMediaResource&, const SharedBuffer&) final;
    void loadFinished(PlatformMediaResource&, const NetworkLoadMetrics&) final;
    
    MediaPlayerPrivateWebM& m_parent;
    RefPtr<PlatformMediaResource> m_resource;
    SharedBufferBuilder m_buffer;
};

WeakPtr<WebMResourceClient> WebMResourceClient::create(MediaPlayerPrivateWebM& parent, PlatformMediaResourceLoader& loader, ResourceRequest&& request)
{
    auto resource = loader.requestResource(WTFMove(request), PlatformMediaResourceLoader::LoadOption::DisallowCaching);
    if (!resource)
        return nullptr;
    auto* resourcePointer = resource.get();
    auto client = adoptRef(*new WebMResourceClient { parent, resource.releaseNonNull() });
    WeakPtr result = client;

    resourcePointer->setClient(WTFMove(client));
    return result;
}

WebMResourceClient::WebMResourceClient(MediaPlayerPrivateWebM& parent, Ref<PlatformMediaResource>&& resource)
    : m_parent(parent)
    , m_resource(WTFMove(resource))
{
}

void WebMResourceClient::stop()
{
    if (!m_resource)
        return;
    
    auto resource = WTFMove(m_resource);
    resource->stop();
    resource->setClient(nullptr);
}

void WebMResourceClient::dataReceived(PlatformMediaResource&, const SharedBuffer& buffer)
{
    m_buffer.append(buffer);
    m_parent.dataReceived(buffer);
}

void WebMResourceClient::loadFinished(PlatformMediaResource&, const NetworkLoadMetrics&)
{
    m_parent.loadFinished(*m_buffer.get());
}

MediaPlayerPrivateWebM::MediaPlayerPrivateWebM(MediaPlayer* player)
    : m_player(player)
    , m_synchronizer(adoptNS([PAL::allocAVSampleBufferRenderSynchronizerInstance() init]))
    , m_networkState(MediaPlayer::NetworkState::Empty)
    , m_readyState(MediaPlayer::ReadyState::HaveNothing)
    , m_logger(player->mediaPlayerLogger())
    , m_logIdentifier(player->mediaPlayerLogIdentifier())
    , m_videoLayerManager(makeUnique<VideoLayerManagerObjC>(m_logger, m_logIdentifier))
    , m_naturalSize(FloatSize())
    , m_hasAudio(false)
    , m_hasVideo(false)
    , m_currentTime(MediaTime::zeroTime())
    , m_duration(MediaTime::zeroTime())
    , m_rate(1)
    , m_seeking(false)
    , m_paused(false)
    , m_visible(false)
{
    INFO_LOG(LOGIDENTIFIER);
}

MediaPlayerPrivateWebM::~MediaPlayerPrivateWebM()
{
    INFO_LOG(LOGIDENTIFIER);
    
    if (m_durationObserver)
        [m_synchronizer removeTimeObserver:m_durationObserver.get()];
    
    destroyLayer();
    destroyAudioRenderer();
}

void MediaPlayerPrivateWebM::dataReceived(const SharedBuffer&)
{
    ALWAYS_LOG(LOGIDENTIFIER);
}

void MediaPlayerPrivateWebM::loadFinished(const FragmentedSharedBuffer& fragmentedBuffer)
{
    ALWAYS_LOG(LOGIDENTIFIER);
    
    auto buffer = fragmentedBuffer.makeContiguous();
    demuxWebMData(buffer);
    
    ensureLayer();
    ensureAudioRenderer();
    enqueueSamples();
    
    setReadyState(MediaPlayer::ReadyState::HaveEnoughData);
    setNetworkState(MediaPlayer::NetworkState::Idle);
    m_player->firstVideoFrameAvailable();
}

static HashSet<String, ASCIICaseInsensitiveHash>& mimeTypeCache()
{
    static NeverDestroyed cache = HashSet<String, ASCIICaseInsensitiveHash> { "video/webm"_s };
    return cache;
}

void MediaPlayerPrivateWebM::load(const String& url)
{
    ALWAYS_LOG(LOGIDENTIFIER, url);
    if (!m_player)
        return;

    auto mimeType = m_player->contentMIMEType();
    if (mimeType.isEmpty() || !mimeTypeCache().contains(mimeType)) {
        setNetworkState(MediaPlayer::NetworkState::FormatError);
        return;
    }
    
    ResourceRequest request(url);
    request.setAllowCookies(true);
    request.setFirstPartyForCookies(URL(url));
    
    auto loader = m_player->createResourceLoader();
    
    ResourceLoaderOptions loaderOptions(
        SendCallbackPolicy::SendCallbacks,
        ContentSniffingPolicy::DoNotSniffContent,
        DataBufferingPolicy::BufferData,
        StoredCredentialsPolicy::DoNotUse,
        ClientCredentialPolicy::CannotAskClientForCredentials,
        FetchOptions::Credentials::Omit,
        SecurityCheckPolicy::DoSecurityCheck,
        FetchOptions::Mode::NoCors,
        CertificateInfoPolicy::DoNotIncludeCertificateInfo,
        ContentSecurityPolicyImposition::DoPolicyCheck,
        DefersLoadingPolicy::AllowDefersLoading,
        CachingPolicy::DisallowCaching
    );
    loaderOptions.destination = FetchOptions::Destination::Video;
    
    m_resourceClient = WebMResourceClient::create(*this, *loader, WTFMove(request));
}

#if ENABLE(MEDIA_SOURCE)
void MediaPlayerPrivateWebM::load(const URL&, const ContentType&, MediaSourcePrivateClient&)
{
    setNetworkState(MediaPlayer::NetworkState::FormatError);
}
#endif

#if ENABLE(MEDIA_STREAM)
void MediaPlayerPrivateWebM::load(MediaStreamPrivate&)
{
    setNetworkState(MediaPlayer::NetworkState::FormatError);
}
#endif

void MediaPlayerPrivateWebM::cancelLoad()
{
    notImplemented();
}

PlatformLayer* MediaPlayerPrivateWebM::platformLayer() const
{
    if (!m_displayLayer)
        return nullptr;
    return m_videoLayerManager->videoInlineLayer();
}

void MediaPlayerPrivateWebM::play()
{
    m_paused = false;
    [m_synchronizer setRate:m_rate];
    
    if (currentMediaTime() >= durationMediaTime())
        seek(MediaTime::zeroTime());
}

void MediaPlayerPrivateWebM::pause()
{
    m_paused = true;
    [m_synchronizer setRate:0];
}

void MediaPlayerPrivateWebM::setPageIsVisible(bool visible)
{
    if (m_visible == visible)
        return;
    
    ALWAYS_LOG(LOGIDENTIFIER, visible);
    m_visible = visible;
    if (visible)
        ensureLayer();
}

MediaTime MediaPlayerPrivateWebM::currentMediaTime() const
{
    MediaTime synchronizerTime = PAL::toMediaTime(PAL::CMTimebaseGetTime([m_synchronizer timebase]));
    if (synchronizerTime < MediaTime::zeroTime())
        return MediaTime::zeroTime();
    if (synchronizerTime > durationMediaTime())
        return durationMediaTime();
    
    return synchronizerTime;
}

void MediaPlayerPrivateWebM::seek(const MediaTime& time)
{
    ALWAYS_LOG(LOGIDENTIFIER, "time = ", time);
    
    [m_displayLayer flush];
    [m_audioRenderer flush];
    enqueueSamplesForTime(time);
    [m_synchronizer setRate:effectiveRate() time:PAL::toCMTime(time)];
    m_player->timeChanged();
}

std::unique_ptr<PlatformTimeRanges> MediaPlayerPrivateWebM::seekable() const
{
    return makeUnique<PlatformTimeRanges>(minMediaTimeSeekable(), maxMediaTimeSeekable());
};

std::unique_ptr<PlatformTimeRanges> MediaPlayerPrivateWebM::buffered() const
{
    return makeUnique<PlatformTimeRanges>(MediaTime::zeroTime(), durationMediaTime());
};

bool MediaPlayerPrivateWebM::didLoadingProgress() const
{
    return false;
};

void MediaPlayerPrivateWebM::setNaturalSize(FloatSize size)
{
    FloatSize oldSize = m_naturalSize;
    m_naturalSize = size;
    if (oldSize != m_naturalSize) {
        INFO_LOG(LOGIDENTIFIER, "was ", oldSize.width(), " x ", oldSize.height(), ", is ", size.width(), " x ", size.height());
        m_player->sizeChanged();
    }
}

void MediaPlayerPrivateWebM::setHasAudio(bool hasAudio)
{
    if (hasAudio == m_hasAudio)
        return;

    m_hasAudio = hasAudio;
    characteristicsChanged();
}

void MediaPlayerPrivateWebM::setHasVideo(bool hasVideo)
{
    if (hasVideo == m_hasVideo)
        return;

    m_hasVideo = hasVideo;
    characteristicsChanged();
}

void MediaPlayerPrivateWebM::setDuration(const MediaTime& duration)
{
    setDuration(MediaTime(duration));
}

void MediaPlayerPrivateWebM::setDuration(MediaTime&& duration)
{
    if (duration == m_duration)
        return;
    
    if (m_durationObserver)
        [m_synchronizer removeTimeObserver:m_durationObserver.get()];
    
    NSArray* times = @[[NSValue valueWithCMTime:PAL::toCMTime(duration)]];
    
    auto logSiteIdentifier = LOGIDENTIFIER;
    DEBUG_LOG(logSiteIdentifier, duration);
    UNUSED_PARAM(logSiteIdentifier);
    
    m_durationObserver = [m_synchronizer addBoundaryTimeObserverForTimes:times queue:dispatch_get_main_queue() usingBlock:[weakThis = WeakPtr { *this }, duration, logSiteIdentifier, this] {
        if (!weakThis)
            return;

        MediaTime now = weakThis->currentMediaTime();
        ALWAYS_LOG(logSiteIdentifier, "boundary time observer called, now = ", now);

        weakThis->pause();
        if (now < duration) {
            ERROR_LOG(logSiteIdentifier, "ERROR: boundary time observer called before duration");
            [weakThis->m_synchronizer setRate:0 time:PAL::toCMTime(duration)];
        }
        weakThis->m_player->timeChanged();

    }];
    
    m_duration = WTFMove(duration);
    m_player->durationChanged();
}

void MediaPlayerPrivateWebM::setRateDouble(double rate)
{
    if (rate == m_rate)
        return;
    
    m_rate = std::max<double>(rate, 0);
    m_player->rateChanged();
}

double MediaPlayerPrivateWebM::effectiveRate() const
{
    return PAL::CMTimebaseGetRate([m_synchronizer timebase]);
}

void MediaPlayerPrivateWebM::setVolume(float volume)
{
    [m_audioRenderer setVolume:volume];
}

void MediaPlayerPrivateWebM::setMuted(bool muted)
{
    [m_audioRenderer setMuted:muted];
}

void MediaPlayerPrivateWebM::setNetworkState(MediaPlayer::NetworkState state)
{
    if (state == m_networkState)
        return;

    m_networkState = state;
    m_player->networkStateChanged();
}

void MediaPlayerPrivateWebM::setReadyState(MediaPlayer::ReadyState state)
{
    if (state == m_readyState)
        return;

    m_readyState = state;
    m_player->readyStateChanged();
}

void MediaPlayerPrivateWebM::characteristicsChanged()
{
    m_player->characteristicChanged();
}

RetainPtr<PlatformLayer> MediaPlayerPrivateWebM::createVideoFullscreenLayer()
{
    return adoptNS([[CALayer alloc] init]);
}

void MediaPlayerPrivateWebM::setVideoFullscreenLayer(PlatformLayer *videoFullscreenLayer, WTF::Function<void()>&& completionHandler)
{
    m_videoLayerManager->setVideoFullscreenLayer(videoFullscreenLayer, WTFMove(completionHandler), nullptr);
}

void MediaPlayerPrivateWebM::setVideoFullscreenFrame(FloatRect frame)
{
    m_videoLayerManager->setVideoFullscreenFrame(frame);
}

bool MediaPlayerPrivateWebM::requiresTextTrackRepresentation() const
{
    return m_videoLayerManager->videoFullscreenLayer();
}
    
void MediaPlayerPrivateWebM::syncTextTrackBounds()
{
    m_videoLayerManager->syncTextTrackBounds();
}
    
void MediaPlayerPrivateWebM::setTextTrackRepresentation(TextTrackRepresentation* representation)
{
    auto* representationLayer = representation ? representation->platformLayer() : nil;
    m_videoLayerManager->setTextTrackRepresentationLayer(representationLayer);
}

void MediaPlayerPrivateWebM::enqueueSamples()
{
    enqueueSamplesForTime(currentMediaTime());
}

void MediaPlayerPrivateWebM::enqueueSamplesForTime(const MediaTime& time)
{
    // Find the sample which contains the current presentation time.
    auto currentSamplePTSIterator = m_videoSamples.presentationOrder().findSampleContainingPresentationTime(time);
    
    if (currentSamplePTSIterator == m_videoSamples.presentationOrder().end()) {
        currentSamplePTSIterator = m_videoSamples.presentationOrder().findSampleStartingOnOrAfterPresentationTime(time);
        
        if (currentSamplePTSIterator == m_videoSamples.presentationOrder().end())
            return;
    }
        
    // Search backward for the previous sync sample.
    DecodeOrderSampleMap::KeyType decodeKey(currentSamplePTSIterator->second->decodeTime(), currentSamplePTSIterator->second->presentationTime());
    auto currentSampleDTSIterator = m_videoSamples.decodeOrder().findSampleWithDecodeKey(decodeKey);
    ASSERT(currentSampleDTSIterator != m_videoSamples.decodeOrder().end());
    
    auto reverseCurrentSampleIter = --DecodeOrderSampleMap::reverse_iterator(currentSampleDTSIterator);
    auto reverseLastSyncSampleIter = m_videoSamples.decodeOrder().findSyncSamplePriorToDecodeIterator(reverseCurrentSampleIter);
    if (reverseLastSyncSampleIter == m_videoSamples.decodeOrder().rend())
        return;
    
    // Enqueue non-displaying samples
    for (auto iter = reverseLastSyncSampleIter; iter != reverseCurrentSampleIter; --iter) {
        auto copy = iter->second->createNonDisplayingCopy();
        auto sampleBuffer = copy.get().platformSample().sample.cmSampleBuffer;
        [m_displayLayer enqueueSampleBuffer:sampleBuffer];
    }
    
    for (auto iter = currentSampleDTSIterator; iter != m_videoSamples.decodeOrder().end(); ++iter) {
        auto sampleBuffer = iter->second.get()->platformSample().sample.cmSampleBuffer;
        
        CMFormatDescriptionRef formatDescription = PAL::CMSampleBufferGetFormatDescription(sampleBuffer);
        auto mediaType = PAL::CMFormatDescriptionGetMediaType(formatDescription);
        
        ASSERT(mediaType == kCMMediaType_Video);
        FloatSize formatSize = FloatSize(PAL::CMVideoFormatDescriptionGetPresentationDimensions(formatDescription, true, true));
        
        if (formatSize != m_naturalSize)
            setNaturalSize(formatSize);
        
        [m_displayLayer enqueueSampleBuffer:sampleBuffer];
        setHasVideo(true);
    }
    

    for (auto& samplePair : m_audioSamples.presentationOrder()) {
        auto sampleBuffer = samplePair.second.get()->platformSample().sample.cmSampleBuffer;

        CMFormatDescriptionRef formatDescription = PAL::CMSampleBufferGetFormatDescription(sampleBuffer);
        auto mediaType = PAL::CMFormatDescriptionGetMediaType(formatDescription);

        if(mediaType == kCMMediaType_Audio) {
            [m_audioRenderer enqueueSampleBuffer:sampleBuffer];
            setHasAudio(true);
        }
    }
}

void MediaPlayerPrivateWebM::demuxWebMData(SharedBuffer& buffer)
{
    auto parser = adoptRef(new SourceBufferParserWebM());
    bool error = false;
    std::optional<uint64_t> videoTrackId;
    std::optional<uint64_t> audioTrackId;
    
    parser->setDidEncounterErrorDuringParsingCallback([&](uint64_t) {
        error = true;
    });
    parser->setDidParseInitializationDataCallback([&](SourceBufferParserWebM::InitializationSegment&& init) {
        for (auto& videoTrack : init.videoTracks) {
            if (videoTrack.track && videoTrack.track->trackUID()) {
                videoTrackId = videoTrack.track->trackUID();
                auto track = static_pointer_cast<VideoTrackPrivateWebM>(videoTrack.track);
                m_videoTracks.append(track);
            }
        }
        
        for (auto& audioTrack : init.audioTracks) {
            if (audioTrack.track && audioTrack.track->trackUID()) {
                audioTrackId = audioTrack.track->trackUID();
                auto track = static_pointer_cast<AudioTrackPrivateWebM>(audioTrack.track);
                m_audioTracks.append(track);
            }
        }
        
        setDuration(WTFMove(init.duration));
    });
    parser->setDidProvideMediaDataCallback([&](Ref<MediaSampleAVFObjC>&& sample, uint64_t trackID, const String&) {
        if (videoTrackId && trackID == *videoTrackId)
            m_videoSamples.addSample(WTFMove(sample));
        else if (audioTrackId && trackID == *audioTrackId)
            m_audioSamples.addSample(WTFMove(sample));
    });
    parser->setCallOnClientThreadCallback([](auto&& function) {
        function();
    });
    SourceBufferParser::Segment segment(Ref { buffer });
    parser->appendData(WTFMove(segment));
}

void MediaPlayerPrivateWebM::ensureLayer()
{
    if (m_displayLayer)
        return;
    
    m_displayLayer = adoptNS([PAL::allocAVSampleBufferDisplayLayerInstance() init]);
#ifndef NDEBUG
    [m_displayLayer setName:@"MediaPlayerPrivateWebM AVSampleBufferDisplayLayer"];
#endif
    
    ERROR_LOG_IF(!m_displayLayer, LOGIDENTIFIER, "Creating the AVSampleBufferDisplayLayer failed.");
    if (!m_displayLayer)
        return;
    
    @try {
        [m_synchronizer addRenderer:m_displayLayer.get()];
    } @catch(NSException *exception) {
        ERROR_LOG(LOGIDENTIFIER, "-[AVSampleBufferRenderSynchronizer addRenderer:] threw an exception: ", [[exception name] UTF8String], ", reason : ", [[exception reason] UTF8String]);
        ASSERT_NOT_REACHED();

        setNetworkState(MediaPlayer::NetworkState::DecodeError);
        return;
    }
    
    m_videoLayerManager->setVideoLayer(m_displayLayer.get(), snappedIntRect(m_player->playerContentBoxRect()).size());
    m_player->renderingModeChanged();
}

void MediaPlayerPrivateWebM::ensureAudioRenderer()
{
    if (m_audioRenderer)
        return;
    
    m_audioRenderer = adoptNS([PAL::allocAVSampleBufferAudioRendererInstance() init]);

    if (!m_audioRenderer) {
        ERROR_LOG(LOGIDENTIFIER, "-[AVSampleBufferAudioRenderer init] returned nil! bailing!");
        ASSERT_NOT_REACHED();
        
        setNetworkState(MediaPlayer::NetworkState::DecodeError);
        return;
    }
    
    [m_audioRenderer setMuted:m_player->muted()];
    [m_audioRenderer setVolume:m_player->volume()];
    [m_audioRenderer setAudioTimePitchAlgorithm:(m_player->preservesPitch() ? AVAudioTimePitchAlgorithmSpectral : AVAudioTimePitchAlgorithmVarispeed)];
    
#if HAVE(AUDIO_OUTPUT_DEVICE_UNIQUE_ID)
    auto deviceId = m_player->audioOutputDeviceIdOverride();
    if (!deviceId.isNull() && m_audioRenderer) {
        if (deviceId.isEmpty())
            m_audioRenderer.get().audioOutputDeviceUniqueID = nil;
        else
            m_audioRenderer.get().audioOutputDeviceUniqueID = deviceId;
    }
#endif
    
    @try {
        [m_synchronizer addRenderer:m_audioRenderer.get()];
    } @catch(NSException *exception) {
        ERROR_LOG(LOGIDENTIFIER, "-[AVSampleBufferRenderSynchronizer addRenderer:] threw an exception: ", [[exception name] UTF8String], ", reason : ", [[exception reason] UTF8String]);
        ASSERT_NOT_REACHED();

        setNetworkState(MediaPlayer::NetworkState::DecodeError);
        return;
    }
    
    characteristicsChanged();
}

void MediaPlayerPrivateWebM::destroyLayer()
{
    if (!m_displayLayer)
        return;
    
    CMTime currentTime = PAL::CMTimebaseGetTime([m_synchronizer timebase]);
    [m_synchronizer removeRenderer:m_displayLayer.get() atTime:currentTime withCompletionHandler:^(BOOL){
        // No-op.
    }];
    
    m_videoLayerManager->didDestroyVideoLayer();
    [m_displayLayer flush];
    [m_displayLayer stopRequestingMediaData];
    m_displayLayer = nullptr;
    m_player->renderingModeChanged();
}

void MediaPlayerPrivateWebM::destroyAudioRenderer()
{
    if (!m_audioRenderer)
        return;
    
    [m_audioRenderer flush];
    [m_audioRenderer stopRequestingMediaData];
    m_audioRenderer = nullptr;
}

void MediaPlayerPrivateWebM::clearTracks()
{
    for (auto& track : m_videoTracks)
        track->setSelectedChangedCallback(nullptr);
    m_videoTracks.clear();

    for (auto& track : m_audioTracks)
        track->setEnabledChangedCallback(nullptr);
    m_audioTracks.clear();
}

WTFLogChannel& MediaPlayerPrivateWebM::logChannel() const
{
    return LogMedia;
}

class MediaPlayerFactoryWebM final : public MediaPlayerFactory {
private:
    MediaPlayerEnums::MediaEngineIdentifier identifier() const final { return MediaPlayerEnums::MediaEngineIdentifier::CocoaWebM; };

    std::unique_ptr<MediaPlayerPrivateInterface> createMediaEnginePlayer(MediaPlayer* player) const final
    {
        return makeUnique<MediaPlayerPrivateWebM>(player);
    }

    void getSupportedTypes(HashSet<String, ASCIICaseInsensitiveHash>& types) const final
    {
        return MediaPlayerPrivateWebM::getSupportedTypes(types);
    }

    MediaPlayer::SupportsType supportsTypeAndCodecs(const MediaEngineSupportParameters& parameters) const final
    {
        return MediaPlayerPrivateWebM::supportsType(parameters);
    }
};

void MediaPlayerPrivateWebM::registerMediaEngine(MediaEngineRegistrar registrar)
{
    if (!isAvailable())
        return;
    
    registrar(makeUnique<MediaPlayerFactoryWebM>());
}

bool MediaPlayerPrivateWebM::isAvailable()
{
    return PAL::isAVFoundationFrameworkAvailable()
        && PAL::isCoreMediaFrameworkAvailable()
        && PAL::getAVSampleBufferAudioRendererClass()
        && PAL::getAVSampleBufferRenderSynchronizerClass()
        && class_getInstanceMethod(PAL::getAVSampleBufferAudioRendererClass(), @selector(setMuted:));
}

void MediaPlayerPrivateWebM::getSupportedTypes(HashSet<String, ASCIICaseInsensitiveHash>& types)
{
    types = mimeTypeCache();
}

MediaPlayer::SupportsType MediaPlayerPrivateWebM::supportsType(const MediaEngineSupportParameters& parameters)
{
    auto containerType = parameters.type.containerType();

    if (!containerType.isEmpty() && mimeTypeCache().contains(containerType)) {
        if (parameters.type.codecs().isEmpty())
            return MediaPlayer::SupportsType::MayBeSupported;

        return MediaPlayer::SupportsType::IsSupported;
    }

    return MediaPlayer::SupportsType::IsNotSupported;
}

} // namespace WebCore

#endif // PLATFORM(COCOA)
