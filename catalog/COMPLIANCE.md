# Upstream compliance record

Every API we considered, the verdict, and why. **Default deny:** an API is listed only when its
terms permit commercial use *and* permit us to call it on behalf of paying third parties.

This file exists so a rejected API does not get re-added later by someone who assumes "it's open".
Several of the best-known "open" APIs are the ones that most explicitly forbid this model.

The machine-readable record — including the decisive clauses quoted verbatim with source URLs —
lives in each entry's `compliance.evidence` array in `catalog/servers/*.json`. Re-verify before
relying on any verdict here: terms change, and a verdict older than the configured maximum age is
treated as unverified and delisted automatically.

Reviewed 2026-09-19. Totals: 19 allowed, 12 not allowed, 6 unknown, of which **17 ship**.

## Science & scholarly

| API | Verdict | Ships | Why |
|---|---|---|---|
| [arXiv API](https://info.arxiv.org/help/api/index.html) | allowed | yes | Metadata is CC0 public domain and the ToU explicitly permits building 'tools and services' that help users discover e-prints -- a direct match for a discovery-oriented gateway. Caution: e-print/PDF content itself may not be stored and re-served from our own servers without permission, so only... |
| [OpenAlex](https://help.openalex.org/) | allowed | yes | OpenAlex's underlying data is CC0 public domain with no personal-use restriction, and the paid/free-tier API pricing model is explicitly usage-based rather than a prohibition on commercial or intermediary use. A shared API key works for our proxy pattern, though heavy volume will draw down the... |
| [Crossref REST API](https://www.crossref.org/documentation/retrieve-metadata/rest-api/) | allowed | yes | Crossref explicitly states almost all metadata may be 'used for any purpose,' with no commercial prohibition, and offers a keyless/mailto-identified public/polite pool suitable for a proxy. Crossref does recommend a paid Metadata Plus subscription for production-scale services, so heavy call... |
| [NCBI PubMed E-utilities](https://www.ncbi.nlm.nih.gov/books/NBK25497/) | allowed | yes | NCBI states it places no restrictions on use or distribution of E-utilities data, and the service is free with only a registered API key needed for higher throughput -- a pattern compatible with a shared-key commercial proxy. Obligations: register the tool/email identifiers with NCBI, display... |
| [Europe PMC REST](https://europepmc.org/RestfulWebService) | allowed | yes | EBI/Europe PMC staff explicitly confirmed on the official developer forum that 'Europe PMC APIs can be used in a commercial web service' and that the API is free, directly matching our resale/proxy pattern. Individual full-text articles retrieved may still carry publisher/author copyright... |
| [PubChem PUG REST](https://pubchem.ncbi.nlm.nih.gov/docs/pug-rest) | allowed | yes | PubChem is an NIH/NCBI public resource provided free of charge with no restriction on use or distribution of the aggregated data, matching a commercial-proxy pattern; NCBI's general policy only asks that redistributors of any copyrighted third-party-submitted records (e.g. certain vendor safety... |
| [NASA Open APIs (APOD, NeoWs)](https://api.nasa.gov/) | allowed | yes | NASA-produced content and open science data are generally public domain and usable for any purpose including commercial, and api.nasa.gov issues free registered keys meant for third-party developer use, fitting a shared-key gateway. Caveat: some APOD images are third-party copyrighted (marked in... |
| [Semantic Scholar Academic Graph API](https://api.semanticscholar.org/api-docs/) | **not allowed** | no | The Semantic Scholar API License Agreement is explicitly non-sublicensable and forbids the Licensee from repackaging, selling, distributing, or sublicensing the API, and requires that the API key not be disclosed beyond the Licensee's own employees/contractors/agents. This directly forbids... |
| [Unpaywall](https://unpaywall.org/products/api) | unknown | no | Unpaywall's own Terms of Service page (unpaywall.org/legal/terms-of-service) is a JavaScript-rendered page that could not be fetched or read despite repeated attempts, so no authoritative commercial-use, resale, or key-sharing clause could be verified. Per the compliance standard,... |
| [Open Library / Internet Archive](https://openlibrary.org/developers/api) | **not allowed** | no | Open Library's own developer documentation explicitly states its APIs 'are not intended to serve as a bulk data backend or high-traffic commercial infrastructure' and that it prioritizes open-source/mission-aligned, non-commercial projects, directly conflicting with a paid, high-volume proxy... |

## Geo, weather & earth

| API | Verdict | Ships | Why |
|---|---|---|---|
| [US National Weather Service API (api.weather.gov)](https://www.weather.gov/documentation/services-web-api) | allowed | yes | The NWS disclaimer says its information is public domain and 'may be used without charge for any lawful purpose' (subject only to no false ownership claim, no implied endorsement, no altered-as-official), and the API page calls the data 'open data, free to use for any purpose'. No key or... |
| [Open-Meteo](https://open-meteo.com/en/docs) | **not allowed** | no | The terms limit the free API to non-commercial purposes ('You may only use the free API services for non-commercial purposes') and count subscription- or ad-funded apps as commercial, so a gateway charging per call cannot use the free endpoint. Only a paid Open-Meteo subscription grants a... |
| [USGS Earthquake Catalog API (FDSN Event Web Service)](https://earthquake.usgs.gov/fdsnws/event/1/) | allowed | yes | USGS states that USGS-authored data and information 'are considered to be in the U.S. Public Domain', and the API needs no key or agreement, so commercial relay is unrestricted apart from a courtesy credit request. The USGS docs publish only a 20,000-event query cap and advise automated apps to... |
| [OpenStreetMap Nominatim (public instance nominatim.openstreetmap.org)](https://operations.osmfoundation.org/policies/nominatim/) | **not allowed** | no | The OSMF Nominatim policy's 'Reselling of geocoding results' section says services whose primary function is related to geocoding 'must run their own service' and names 'API resellers like Postman or Apify'; a paid per-call proxy to the public instance is that pattern. It also caps use at 1... |
| [REST Countries](https://restcountries.com/) | **not allowed** | no | The ToS (last updated 13 August 2026) limits the Free plan to 'prototyping, evaluation, and non-commercial use', requires a paid plan for any revenue-generating use including cached or derived responses, and prohibits reselling or sublicensing the Service or its outputs without written consent.... |
| [Sunrise-Sunset.org API (v2)](https://sunrise-sunset.org/api) | unknown | no | The API page says the API is free with no key but requires an attribution link, and it is silent on commercial use or relaying, while the site-wide Terms of use say 'This site is for personal use only' and forbid automated extraction. The API-specific terms are silent or conflicting with the... |
| [GeoNames Web Services](https://www.geonames.org/export/web-services.html) | allowed | no | Terms are permissive, but no runnable MCP server exists — the only candidate is a wrapper around a third-party hosted gateway. |
| [OpenAQ API (v3)](https://docs.openaq.org/) | **not allowed** | no | OpenAQ's terms bar using the hosted API to 'develop products or services that substantially duplicate or directly compete' with its core offering, limit each individual to one API key that cannot be transferred to another user, and require a separate paid agreement for volume beyond 60/min and... |
| [NOAA Tides & Currents (CO-OPS) Data API](https://api.tidesandcurrents.noaa.gov/api/prod/) | allowed | yes | The CO-OPS disclaimer says information on government servers is in the public domain and 'may be used freely by the public', with only a request for attribution and a ban on presenting modified content as official. No key or agreement is needed; the API only throttles heavy load from a single... |

## Finance, economics & government

| API | Verdict | Ships | Why |
|---|---|---|---|
| [Frankfurter exchange-rate API (ECB reference rates)](https://frankfurter.dev/) | allowed | yes | Frankfurter's own FAQ explicitly says commercial use is free with no key and no quotas, and the underlying ECB source permits free reuse subject only to accurate citation and a notice-to-buyers clause if resold — both compatible with a paid proxy. No clause forbids intermediary/proxy use. |
| [World Bank Indicators API](https://datahelpdesk.worldbank.org/knowledgebase/articles/889392-about-the-indicators-api-documentation) | allowed | yes | World Bank data (CC BY 4.0) explicitly permits commercial use and redistribution with attribution, and the Indicators API needs no key. Caveat: a subset of indicators sourced from third parties are marked non-redistributable, so a gateway should exclude/flag those specific series. |
| [FRED (St. Louis Fed) API](https://fred.stlouisfed.org/docs/api/fred/) | **not allowed** | no | FRED's own key-issuance policy states each application's end users "shall use their own API key," directly conflicting with our shared-key, many-users-per-key proxy pattern; some data series are third-party-owned and require contacting the owner before non-personal use. This matches the... |
| [SEC EDGAR data APIs](https://www.sec.gov/search-filings/edgar-application-programming-interfaces) | allowed | yes | SEC states site/EDGAR content "is considered public information and may be copied or further distributed... without the SEC's permission," needs no key, and only imposes a 10 req/s fair-access limit plus a User-Agent identification requirement — nothing bars a paid intermediary. |
| [US Treasury FiscalData API](https://fiscaldata.treasury.gov/api-documentation/) | allowed | yes | Treasury explicitly states its Fiscal Data is "offered free, without restriction, and available to copy, adapt, redistribute, or otherwise use for non-commercial or commercial purposes," with no key required and no proxy/resale prohibition found. |
| [BLS Public Data API](https://www.bls.gov/developers/) | allowed | yes | BLS states its published data is public domain and free to use without specific permission, and its Terms of Service say end-use is not controlled; no clause restricts commercial resale or proxying, only citation/no-falsification requirements and a registration key for higher quota. |
| [CoinGecko API (free/Demo tier)](https://www.coingecko.com/en/api/pricing) | **not allowed** | no | CoinGecko's own plan comparison labels the free Demo plan license as "Attribution required" (not "Commercial"), and support docs state the Demo plan does not allow commercial use — commercial license only starts at paid plans; the API Terms also separately forbid sub-licensing or redistributing... |
| [Alpha Vantage API (free tier)](https://www.alphavantage.co/documentation/) | **not allowed** | no | Alpha Vantage's Terms grant the free key only for "personal, non-commercial use" and define commercial use to explicitly include letting other individuals or entities access the data through the user's access — precisely our proxy pattern — directing such use to a separate paid/commercial... |
| [Data.gov / CKAN catalog API](https://www.data.gov/developers/apis/) | allowed | no | Terms are permissive, but catalog.data.gov retired its CKAN API in 2025 and the endpoint returns 404. Would need GSA's keyed v4 API. |

## Knowledge, developer & web

| API | Verdict | Ships | Why |
|---|---|---|---|
| [Wikimedia/Wikipedia REST & Action APIs](https://www.mediawiki.org/wiki/Wikimedia_APIs) | **not allowed** | no | The Foundation's API Usage Guidelines explicitly bar operators from sublicensing, leasing, assigning, or guaranteeing availability of a Wikimedia-managed API to any third party, and the Robot policy directs high-volume/commercial operators to the paid Wikimedia Enterprise API instead. A gateway... |
| [Wikidata Query Service (SPARQL)](https://www.wikidata.org/wiki/Wikidata:Data_access) | **not allowed** | no | Although the underlying data is CC0 (public domain, commercial use clearly fine), WDQS is a Wikimedia Foundation-managed API subject to the same sub-licensing/no-third-party-resale clause as the Action/REST APIs, and its own docs recommend the paid Wikimedia Enterprise API or local replicas for... |
| [Hacker News API (Firebase)](https://github.com/HackerNews/API) | unknown | no | The API repo (MIT-licensed docs/code) imposes no rate limit and no key, and was built specifically to expose public HN data broadly, but there is no explicit statement anywhere permitting commercial resale or third-party proxying of the API itself. Y Combinator's site-wide Terms of Use... |
| [GitHub REST API (shared server token)](https://docs.github.com/en/rest) | **not allowed** | no | GitHub's Terms of Service (Section H, API Terms) expressly prohibit sharing API tokens to exceed rate limits and state that high-throughput access "that would result in resale of GitHub's Service" requires a separate paid subscription arrangement; Section B additionally bars a single login/token... |
| [npm registry API](https://github.com/npm/registry/blob/main/docs/REGISTRY-API.md) | allowed | yes | npm's Open Source Terms explicitly permit replicating registry data via the documented Public APIs and place no blanket ban on commercial use of ordinary package metadata (only a narrower restriction applies to redistributing Package security/vulnerability data). As long as request volume stays... |
| [PyPI JSON API](https://docs.pypi.org/api/json/) | allowed | yes | The JSON API is unauthenticated (no token to share), is explicitly documented as unrate-limited at the edge, and PyPI's Terms of Service only bar excessive/abusive request volume and API-token sharing (not applicable to a keyless metadata endpoint) or using the API to scrape user PII for spam.... |
| [Stack Exchange API](https://api.stackexchange.com/docs) | unknown | no | stackoverflow.com and stackexchange.com are not fetchable from this environment (blocked host), so the primary API Terms of Use could not be directly verified; only secondary evidence (the MCP server's own README) was obtainable. Per the evidence rules, a verdict cannot be based on an un-fetched... |
| [Free Dictionary API (dictionaryapi.dev)](https://dictionaryapi.dev/) | unknown | no | dictionaryapi.dev has no published Terms of Service, rate limit, or commercial-use statement of its own; it is a free, donation-funded hobby project wrapping Wiktionary (CC BY-SA) data. The underlying data license permits commercial reuse with attribution, but the absence of any usage agreement... |
| [Datamuse API](https://www.datamuse.com/api/) | unknown | no | Datamuse's site does not forbid commercial use outright, but it explicitly asks operators who want to embed the API in a customer-facing application to first contact them and describe the application rather than proceeding unilaterally - exactly the scenario of a paid multi-tenant gateway.... |

## What the rejections have in common

The barrier is almost never the data licence — it is the *access* terms sitting on top of it.

- **One key per user.** FRED requires every user of an application to hold their own key;
  Semantic Scholar's licence is non-sublicensable; OpenAQ issues one non-transferable key per
  individual. A shared gateway key breaks all three.
- **Reselling named explicitly.** OpenStreetMap's Nominatim usage policy names API resellers as
  forbidden. Wikimedia bans sublicensing a WMF-managed API and points commercial volume at paid
  Wikimedia Enterprise. GitHub bans sharing one token to exceed rate limits.
- **Free tier means non-commercial.** CoinGecko's demo tier and Alpha Vantage's free tier are
  licensed for attribution/non-commercial use, whatever the data is.
- **Open content, closed pipe.** Wikipedia (CC BY-SA), Wikidata (CC0) and Open Library (public
  domain) all have reusable *content* but terms that forbid this *delivery* model.

Where terms permit some endpoints but not others, the entry ships with `exclude_tools` rather
than being dropped: arXiv allows discovery but not serving e-print full text, and PubMed article
full text carries publisher copyright separate from the metadata.

## Unknown verdicts

Unknown is a real answer, not a soft yes. These are excluded until someone verifies them:

- **Sunrise-Sunset.org API (v2)** — The API page says the API is free with no key but requires an attribution link, and it is silent on commercial use or relaying, while the site-wide Terms of use say 'This site is for personal use only' and forbid automat
- **Hacker News API (Firebase)** — The API repo (MIT-licensed docs/code) imposes no rate limit and no key, and was built specifically to expose public HN data broadly, but there is no explicit statement anywhere permitting commercial resale or third-party
- **Stack Exchange API** — stackoverflow.com and stackexchange.com are not fetchable from this environment (blocked host), so the primary API Terms of Use could not be directly verified; only secondary evidence (the MCP server's own README) was ob
- **Free Dictionary API (dictionaryapi.dev)** — dictionaryapi.dev has no published Terms of Service, rate limit, or commercial-use statement of its own; it is a free, donation-funded hobby project wrapping Wiktionary (CC BY-SA) data. The underlying data license permit
- **Datamuse API** — Datamuse's site does not forbid commercial use outright, but it explicitly asks operators who want to embed the API in a customer-facing application to first contact them and describe the application rather than proceedi
- **Unpaywall** — Unpaywall's own Terms of Service page (unpaywall.org/legal/terms-of-service) is a JavaScript-rendered page that could not be fetched or read despite repeated attempts, so no authoritative commercial-use, resale, or key-s

