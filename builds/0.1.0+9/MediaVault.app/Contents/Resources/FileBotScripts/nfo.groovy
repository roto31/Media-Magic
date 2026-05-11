#!/usr/bin/env -S filebot -script


def fetchMovieNfo(m, f) {
	def nfoFile = f.dir / 'movie.nfo'
	if (nfoFile.exists()) {
		log.finest "[SKIP] NFO already exists: $nfoFile"
		return
	}

	log.info "Generate Movie NFO: $m [$nfoFile]"
	def i = m.info

	def xml = XML {
		movie {
			id(i.id)
			title(i.name)
			originaltitle(i.originalName)
			sorttitle((i.collection && i.released ? [i.collection, i.released, i.name] : [i.name, i.released]).findResults{ it?.toString()?.sortName() }.join(' :: '))
			year(i.released?.year)
			premiered(i.released)
			mpaa(i.certification)
			plot(i.overview)
			tagline(i.tagline)
			runtime(i.runtime)
			status(i.status)

			ratings {
				rating(name: 'tmdb', max: '10', default: 'true') {
					value(i.rating)
					votes(i.votes)
				}
			}

			if (Settings.ApplicationRevisionNumber > 10960) {
				if (i.collection) {
					set(id: m.collection.id) {
						name(m.collection.name)
						overview(m.collection.overview)
					}
				}
			}

			i.genres.each{ g ->
				genre(g)
			}
			i.keywords.each{ k ->
				tag(k)
			}
			i.productionCountries.each{ c ->
				country(c)
			}
			i.productionCompanies.each{ c ->
				studio(c)
			}

			m.artwork.findAll{ a -> a.matches(/posters/) }.take(1).each{ a ->
				thumb(aspect: 'poster', a.url)
			}

			m.artwork.findAll{ a -> a.matches(/backdrops/) }.take(1).each{ a ->
				fanart {
					thumb(a.url)
				}
			}

			certificationFragment(delegate, i)
			crewFragment(delegate, i)
			fileFragment(delegate, f)

			if (i.imdbId) {
				imdb(id: 'tt' + i.imdbId.pad(7), 'https://www.imdb.com/title/tt' + i.imdbId.pad(7))
			}
			tmdb(id: i.id, 'https://www.themoviedb.org/movie/' + i.id)
			uniqueid(type: 'tmdb', default: 'true', i.id)
		}
	}

	// write movie nfo file
	xml.saveAs(nfoFile)
}


def fetchSeriesNfo(m, f) {
	def seriesFolder = f.dir.dir
	if (!seriesFolder || !seriesFolder.name) {
		log.finest "[SKIP] Invalid series folder: $f"
		return
	}

	def nfoFile = seriesFolder / 'tvshow.nfo'
	if (nfoFile.exists()) {
		log.finest "[SKIP] NFO already exists: $nfoFile"
		return
	}

	log.info "Generate Series NFO: $m.seriesInfo [$nfoFile]"
	def s = m.seriesInfo.details
	def db = db(s.database)

	def xml = XML {
		tvshow {
			id(s.id)
			title(s.name)
			sorttitle([s.name, s.startDate].findResults{ it?.toString()?.sortName() }.join(' :: '))
			year(s.startDate?.year)
			premiered(s.startDate)
			mpaa(s.certification)
			plot(s.overview)
			runtime(s.runtime)

			ratings {
				rating(name: db, max: '10', default: 'true') {
					value(s.rating)
					votes(s.ratingCount)
				}
			}

			status(s.status)
			studio(s.network)

			episodeguide(s.id)

			s.episodes.collectEntries{ e -> [e.episode ? e.season : 0, e.group] }.each{ seasonNumber, seasonName ->
				if (seasonName) {
					namedseason(number: seasonNumber, seasonName)
				}
			}

			s.genres.each{ g ->
				genre(g)
			}
			s.country.each{ c ->
				country(c)
			}

			s.artwork.findAll{ a -> a.matches(/posters/) }.take(1).each{ a ->
				thumb(aspect: 'poster', a.url)
			}
			s.artwork.findAll{ a -> a.matches(/logos/) }.take(1).each{ a ->
				thumb(aspect: 'clearlogo', a.url)
			}
			s.artwork.findAll{ a -> a.matches(/backdrops/) }.take(1).each{ a ->
				fanart {
					thumb(a.url)
				}
			}

			certificationFragment(delegate, s)
			crewFragment(delegate, s)

			if (s.database =~ /TheMovieDB/) {
				tmdb(id: s.id, 'https://www.themoviedb.org/tv/' + s.id)
			}
			if (s.database =~ /TheTVDB/) {
				tvdb(id: s.id, 'https://thetvdb.com/series/' + s.slug)
			}
			if (s.database =~ /AniDB/) {
				anidb(id: s.id, 'https://anidb.net/anime/' + s.id)
			}

			uniqueid(type: db, default: 'true', s.id)
		}
	}

	// write series nfo file
	xml.saveAs(nfoFile)
}


def fetchEpisodeNfo(m, f) {
	def nfoFile = f.dir / f.nameWithoutExtension + '.nfo'
	if (nfoFile.exists()) {
		log.finest "[SKIP] NFO already exists: $nfoFile"
		return
	}

	log.info "Generate Episode NFO: $m [$nfoFile]"
	def s = m.seriesInfo

	def xml = XML {
		m.each{ episodePart ->
			// retrieve episode information for each episode or multi-episode component
			def e = episodePart.info
			if (e == null) {
				return
			}

			episodedetails {
				id(e.id)
				showtitle(s.name)
				title(e.title)
				if (episodePart.group) {
					group(episodePart.group)
				}
				season(episodePart.episode ? episodePart.season : 0)
				episode(episodePart.episode ?: episodePart.special)
				aired(e.airdate)
				premiered(e.airdate)
				plot(e.overview)
				thumb(e.image)

				crewFragment(delegate, e)
				fileFragment(delegate, f)

				uniqueid(type: db(s.database), default: 'true', series: s.id, season: e.season, episode: e.episode, e.id)
			}
		}
	}

	if (xml.empty) {
		log.warning "Episode NFO not supported: $s"
		return
	}

	// write episode nfo file
	xml.saveAs(nfoFile)
}


def crewFragment(element, info) {
	info.crew.each{ p ->
		if (p.actor) { 
			element.actor {
				name(p.name)
				if (p.character) {
					role(p.character)
				}
				if (Settings.ApplicationRevisionNumber > 10960) {
					if (p.order >= 0) {
						order(p.order)
					}
				}
				if (p.image) {
					thumb(p.image)
				}
			}
		} else if (p.director) {
			element.director(p.name)
		} else if (p.writer || p.department == 'Writing') {
			element.credits(p.name)
		}
	}
}


def certificationFragment(element, info) {
	info.certifications.each{ k, v ->
		element.certification {
			country(k)
			rating(v)
		}
	}
}



def fileFragment(element, file) {
	def mi = file.mediaInfo

	element.fileinfo {
		name(file.name)
		size(file.length())

		streamdetails {
			mi.Video.each{ s ->
				video {
					codec(s.'Encoded_Library/Name' ?: s.'CodecID/Hint' ?: s.'Format')
					aspect(s.'DisplayAspectRatio/String')
					width(s.'Width')
					height(s.'Height')
					hdrtype(s.'HDR_Format_Commercial' ?: s.'HDR_Format')
					framerate(s.'FrameRate')
					bitrate(s.'BitRate')
					duration(s.'Duration'.toFloat().div(60000).round(4))
				}
			}
			mi.Audio.each{ s ->
				audio {
					codec(s.'CodecID/Hint' ?: s.'Format')
					language(s.'Language/String3')
					channels(s.'Channel(s)_Original' ?: s.'Channel(s)')
					bitrate(s.'BitRate')
				}
			}
			mi.Text.each{ s ->
				subtitle {
					codec(s.'Format')
					language(s.'Language/String3')
				}
			}
		}
	}
}


def db(database) {
	return database.match('TheMovieDB':'tmdb', 'TheTVDB':'tvdb', 'AniDB':'anidb', 'TVmaze':'tvmaze')
}




def videoFiles = args.getFiles{ it.video }

// require input arguments
if (args.size() == 0) {
	die "Illegal usage: no input arguments"
}

// require video files
if (videoFiles.size() == 0) {
	die "Illegal usage: no video files"
}


videoFiles.each{ f ->
	def m = f.metadata
	switch(m) {
		case Movie:
			log.finest "[MOVIE] $m [$f]"
			fetchMovieNfo(m, f)
			break
		case Episode:
			log.finest "[EPISODE] $m [$f]"
			fetchSeriesNfo(m, f)
			fetchEpisodeNfo(m, f)
			break;
		default:
			log.finest "[XATTR NOT FOUND] $f"
			break
	}
}
