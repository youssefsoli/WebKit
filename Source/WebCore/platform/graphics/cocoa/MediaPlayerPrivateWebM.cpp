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

#include "config.h"
#include "MediaPlayerPrivateWebM.h"

#if PLATFORM(COCOA) && ENABLE(WEBM_EXPERIMENT)

#include "FloatSize.h"
#include "Logging.h"
#include "MediaPlayer.h"

namespace WebCore {

MediaPlayerPrivateWebM::MediaPlayerPrivateWebM(MediaPlayer* player)
    : m_player(player)
    , m_networkState(MediaPlayer::NetworkState::Empty)
    , m_readyState(MediaPlayer::ReadyState::HaveNothing)
#if !RELEASE_LOG_DISABLED
    , m_logger(player->mediaPlayerLogger())
    , m_logIdentifier(player->mediaPlayerLogIdentifier())
#endif
    , m_naturalSize(FloatSize(1280, 720))
    , m_hasAudio(false)
    , m_hasVideo(false)
    , m_seeking(false)
    , m_paused(false)
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
    if (mimeType.isEmpty() || !mimeTypeCache().contains(mimeType))
        setNetworkState(MediaPlayer::NetworkState::FormatError);
}

#if ENABLE(MEDIA_SOURCE)
void MediaPlayerPrivateWebM::load(const URL&, const ContentType&, MediaSourcePrivateClient&)
{
    setNetworkState(MediaPlayer::NetworkState::FormatError);
}
#endif

void MediaPlayerPrivateWebM::cancelLoad()
{
    notImplemented();
}

void MediaPlayerPrivateWebM::play()
{
    notImplemented();
}

void MediaPlayerPrivateWebM::pause()
{
    notImplemented();
}

void MediaPlayerPrivateWebM::setPageIsVisible(bool)
{
    notImplemented();
}

void MediaPlayerPrivateWebM::paint(GraphicsContext&, const FloatRect&)
{
    notImplemented();
}

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

#if !RELEASE_LOG_DISABLED
WTFLogChannel& MediaPlayerPrivateWebM::logChannel() const
{
    return LogMedia;
}
#endif

class MediaPlayerFactoryWebM final : public MediaPlayerFactory {
private:
    MediaPlayerEnums::MediaEngineIdentifier identifier() const final { return MediaPlayerEnums::MediaEngineIdentifier::WebM; };

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
