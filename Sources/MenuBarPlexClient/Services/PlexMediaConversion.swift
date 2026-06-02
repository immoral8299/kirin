import Foundation

extension PlexServer {
    var mediaServer: MediaServer {
        MediaServer(id: id, name: name, accessToken: accessToken, baseURL: baseURL)
    }
}

extension PlexMusicLibrary {
    var mediaMusicLibrary: MediaMusicLibrary {
        MediaMusicLibrary(id: id, title: title, uuid: uuid)
    }
}

extension PlexAlbum {
    var mediaAlbum: MediaAlbum {
        MediaAlbum(id: id, title: title, artist: artist, artworkURL: artworkURL)
    }
}

extension PlexTrack {
    var mediaTrack: MediaTrack {
        MediaTrack(
            id: id,
            playQueueItemID: playQueueItemID,
            ratingKey: ratingKey,
            albumRatingKey: albumRatingKey,
            durationMilliseconds: durationMilliseconds,
            title: title,
            trackArtist: trackArtist,
            albumArtist: albumArtist,
            albumName: albumName,
            artworkURL: artworkURL,
            trackNumber: trackNumber,
            discNumber: discNumber,
            streamURL: streamURL
        )
    }
}

extension PlexPlaylist {
    var mediaPlaylist: MediaPlaylist {
        MediaPlaylist(id: id, title: title, trackCount: trackCount)
    }
}

extension PlexStation {
    var mediaStation: MediaStation {
        MediaStation(id: id, title: title, key: key)
    }
}

extension PlexHomeContent {
    var mediaHomeContent: MediaHomeContent {
        MediaHomeContent(
            recentlyPlayedAlbums: recentlyPlayedAlbums.map(\.mediaAlbum),
            recentlyAddedAlbums: recentlyAddedAlbums.map(\.mediaAlbum),
            playlists: playlists.map(\.mediaPlaylist),
            stations: stations.map(\.mediaStation)
        )
    }
}

extension PlexPlayQueueSnapshot {
    var mediaPlayQueueSnapshot: PlayQueueSnapshot {
        PlayQueueSnapshot(
            id: id,
            totalCount: totalCount,
            selectedTrackID: selectedTrackID,
            version: version,
            isShuffled: isShuffled,
            tracks: tracks.map(\.mediaTrack)
        )
    }
}
