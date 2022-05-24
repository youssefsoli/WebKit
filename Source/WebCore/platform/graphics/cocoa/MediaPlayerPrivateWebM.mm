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

class WebMVideoData {
    WTF_MAKE_FAST_ALLOCATED;
public:
    Ref<SharedBuffer> m_buffer;
#if ENABLE(MEDIA_SOURCE)
    Ref<VideoTrackPrivateWebM> m_track;
#endif
    MediaTime m_duration;
    SampleMap m_samples;
};

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
    , m_seeking(false)
    , m_paused(false)
    , m_visible(false)
{
    INFO_LOG(LOGIDENTIFIER);
}

MediaPlayerPrivateWebM::~MediaPlayerPrivateWebM()
{
    INFO_LOG(LOGIDENTIFIER);
}

static HashSet<String, ASCIICaseInsensitiveHash>& mimeTypeCache()
{
    static NeverDestroyed cache = HashSet<String, ASCIICaseInsensitiveHash> { "video/webm"_s };
    return cache;
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
    [m_synchronizer setRate:1];
    m_player->rateChanged();
}

void MediaPlayerPrivateWebM::pause()
{
    m_paused = true;
    [m_synchronizer setRate:0];
    m_player->rateChanged();
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
    
    return synchronizerTime;
}

std::unique_ptr<PlatformTimeRanges> MediaPlayerPrivateWebM::buffered() const
{
    return makeUnique<PlatformTimeRanges>();
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
    if (duration == m_duration)
        return;

    m_duration = duration;
    m_player->durationChanged();
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

void MediaPlayerPrivateWebM::dataReceived(const SharedBuffer&)
{
    ALWAYS_LOG(LOGIDENTIFIER);
}

void MediaPlayerPrivateWebM::loadFinished(const FragmentedSharedBuffer& fragmentedBuffer)
{
    ALWAYS_LOG(LOGIDENTIFIER);
    
    auto buffer = fragmentedBuffer.makeContiguous();
    m_webmData = demuxWebMData(buffer);
    ensureLayer();
    for (auto& samplePair : m_webmData->m_samples.presentationOrder()) {
        auto sampleBuffer = samplePair.second.get()->platformSample().sample.cmSampleBuffer;
        CMFormatDescriptionRef formatDescription = PAL::CMSampleBufferGetFormatDescription(sampleBuffer);
        FloatSize formatSize = FloatSize(PAL::CMVideoFormatDescriptionGetPresentationDimensions(formatDescription, true, true));
        
        if (formatSize != m_naturalSize)
            setNaturalSize(formatSize);
        
        [m_displayLayer enqueueSampleBuffer:sampleBuffer];
    }
    setReadyState(MediaPlayer::ReadyState::HaveEnoughData);
    setHasVideo(true);
    setDuration(m_webmData->m_duration);
    setNetworkState(MediaPlayer::NetworkState::Idle);
}

std::unique_ptr<WebMVideoData> MediaPlayerPrivateWebM::demuxWebMData(SharedBuffer& buffer)
{
    auto parser = adoptRef(new SourceBufferParserWebM());
    bool error = false;
    std::optional<uint64_t> videoTrackId;
    MediaTime duration;
    RefPtr<VideoTrackPrivateWebM> track;
    SampleMap samples;
    
    parser->setDidEncounterErrorDuringParsingCallback([&](uint64_t) {
        error = true;
    });
    parser->setDidParseInitializationDataCallback([&](SourceBufferParserWebM::InitializationSegment&& init) {
        for (auto& videoTrack : init.videoTracks) {
            if (videoTrack.track && videoTrack.track->trackUID()) {
                duration = init.duration;
                videoTrackId = videoTrack.track->trackUID();
                track = static_pointer_cast<VideoTrackPrivateWebM>(videoTrack.track);
                return;
            }
        }
    });
    parser->setDidProvideMediaDataCallback([&](Ref<MediaSampleAVFObjC>&& sample, uint64_t trackID, const String&) {
        if (!videoTrackId || trackID != *videoTrackId)
            return;
        samples.addSample(WTFMove(sample));
    });
    parser->setCallOnClientThreadCallback([](auto&& function) {
        function();
    });
    SourceBufferParser::Segment segment(Ref { buffer });
    parser->appendData(WTFMove(segment));
    if (!track)
        return nullptr;
    return makeUnique<WebMVideoData>(WebMVideoData { buffer, track.releaseNonNull(), WTFMove(duration), WTFMove(samples) });
}

void MediaPlayerPrivateWebM::ensureLayer()
{
    if (m_displayLayer)
        return;
    
    m_displayLayer = adoptNS([PAL::allocAVSampleBufferDisplayLayerInstance() init]);
#ifndef NDEBUG
    [m_displayLayer setName:@"MediaPlayerPrivateMediaSource AVSampleBufferDisplayLayer"];
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
    registrar(makeUnique<MediaPlayerFactoryWebM>());
}

} // namespace WebCore

#endif // PLATFORM(COCOA)
