// Copyright (c) Tracive. Licensed under the Apache License, Version 2.0.

/// The countries this SDK can turn a locally-formatted phone number into E.164
/// for.
///
/// Generated from the same table the Tracive app uses, and pinned by
/// `phone-normalization-vectors.json`, vendored byte-identically into all four
/// SDK repositories. App and SDK must fold the same person to the same record
/// key; a country table that drifted would produce two keys for one number and
/// neither would find the other's reports.
///
/// [alpha3] is the canonical code everywhere in this SDK — `IDN`, not `ID`. The
/// alpha-2 code is carried only because flag emoji and OS locales need it.
///
/// Several countries share a [dialCode] — 25 of them share `1` — so a dial code
/// cannot be turned back into a country. That direction is not offered.
enum Country {
  /// Aruba — `ABW`, dial code `+297`.
  abw("297", "AW", "ABW", "Aruba"),

  /// Afghanistan — `AFG`, dial code `+93`.
  afg("93", "AF", "AFG", "Afghanistan"),

  /// Angola — `AGO`, dial code `+244`.
  ago("244", "AO", "AGO", "Angola"),

  /// Anguilla — `AIA`, dial code `+1`.
  aia("1", "AI", "AIA", "Anguilla"),

  /// Albania — `ALB`, dial code `+355`.
  alb("355", "AL", "ALB", "Albania"),

  /// Andorra — `AND`, dial code `+376`.
  and("376", "AD", "AND", "Andorra"),

  /// United Arab Emirates — `ARE`, dial code `+971`.
  are("971", "AE", "ARE", "United Arab Emirates"),

  /// Argentina — `ARG`, dial code `+54`.
  arg("54", "AR", "ARG", "Argentina"),

  /// Armenia — `ARM`, dial code `+374`.
  arm("374", "AM", "ARM", "Armenia"),

  /// Ascension Island — `ASC`, dial code `+247`.
  asc("247", "AC", "ASC", "Ascension Island"),

  /// American Samoa — `ASM`, dial code `+1`.
  asm("1", "AS", "ASM", "American Samoa"),

  /// Antigua and Barbuda — `ATG`, dial code `+1`.
  atg("1", "AG", "ATG", "Antigua and Barbuda"),

  /// Australia — `AUS`, dial code `+61`.
  aus("61", "AU", "AUS", "Australia"),

  /// Austria — `AUT`, dial code `+43`.
  aut("43", "AT", "AUT", "Austria"),

  /// Azerbaijan — `AZE`, dial code `+994`.
  aze("994", "AZ", "AZE", "Azerbaijan"),

  /// Burundi — `BDI`, dial code `+257`.
  bdi("257", "BI", "BDI", "Burundi"),

  /// Belgium — `BEL`, dial code `+32`.
  bel("32", "BE", "BEL", "Belgium"),

  /// Benin — `BEN`, dial code `+229`.
  ben("229", "BJ", "BEN", "Benin"),

  /// Caribbean Netherlands — `BES`, dial code `+599`.
  bes("599", "BQ", "BES", "Caribbean Netherlands"),

  /// Burkina Faso — `BFA`, dial code `+226`.
  bfa("226", "BF", "BFA", "Burkina Faso"),

  /// Bangladesh — `BGD`, dial code `+880`.
  bgd("880", "BD", "BGD", "Bangladesh"),

  /// Bulgaria — `BGR`, dial code `+359`.
  bgr("359", "BG", "BGR", "Bulgaria"),

  /// Bahrain — `BHR`, dial code `+973`.
  bhr("973", "BH", "BHR", "Bahrain"),

  /// Bahamas — `BHS`, dial code `+1`.
  bhs("1", "BS", "BHS", "Bahamas"),

  /// Bosnia and Herzegovina — `BIH`, dial code `+387`.
  bih("387", "BA", "BIH", "Bosnia and Herzegovina"),

  /// Saint Barthélemy — `BLM`, dial code `+590`.
  blm("590", "BL", "BLM", "Saint Barthélemy"),

  /// Belarus — `BLR`, dial code `+375`.
  blr("375", "BY", "BLR", "Belarus"),

  /// Belize — `BLZ`, dial code `+501`.
  blz("501", "BZ", "BLZ", "Belize"),

  /// Bermuda — `BMU`, dial code `+1`.
  bmu("1", "BM", "BMU", "Bermuda"),

  /// Bolivia — `BOL`, dial code `+591`.
  bol("591", "BO", "BOL", "Bolivia"),

  /// Brazil — `BRA`, dial code `+55`.
  bra("55", "BR", "BRA", "Brazil"),

  /// Barbados — `BRB`, dial code `+1`.
  brb("1", "BB", "BRB", "Barbados"),

  /// Brunei — `BRN`, dial code `+673`.
  brn("673", "BN", "BRN", "Brunei"),

  /// Bhutan — `BTN`, dial code `+975`.
  btn("975", "BT", "BTN", "Bhutan"),

  /// Botswana — `BWA`, dial code `+267`.
  bwa("267", "BW", "BWA", "Botswana"),

  /// Central African Republic — `CAF`, dial code `+236`.
  caf("236", "CF", "CAF", "Central African Republic"),

  /// Canada — `CAN`, dial code `+1`.
  can("1", "CA", "CAN", "Canada"),

  /// Cocos [Keeling] Islands — `CCK`, dial code `+61`.
  cck("61", "CC", "CCK", "Cocos [Keeling] Islands"),

  /// Switzerland — `CHE`, dial code `+41`.
  che("41", "CH", "CHE", "Switzerland"),

  /// Chile — `CHL`, dial code `+56`.
  chl("56", "CL", "CHL", "Chile"),

  /// China — `CHN`, dial code `+86`.
  chn("86", "CN", "CHN", "China"),

  /// Côte d'Ivoire — `CIV`, dial code `+225`.
  civ("225", "CI", "CIV", "Côte d'Ivoire"),

  /// Cameroon — `CMR`, dial code `+237`.
  cmr("237", "CM", "CMR", "Cameroon"),

  /// Democratic Republic Congo — `COD`, dial code `+243`.
  cod("243", "CD", "COD", "Democratic Republic Congo"),

  /// Republic of Congo — `COG`, dial code `+242`.
  cog("242", "CG", "COG", "Republic of Congo"),

  /// Cook Islands — `COK`, dial code `+682`.
  cok("682", "CK", "COK", "Cook Islands"),

  /// Colombia — `COL`, dial code `+57`.
  col("57", "CO", "COL", "Colombia"),

  /// Comoros — `COM`, dial code `+269`.
  com("269", "KM", "COM", "Comoros"),

  /// Cape Verde — `CPV`, dial code `+238`.
  cpv("238", "CV", "CPV", "Cape Verde"),

  /// Costa Rica — `CRI`, dial code `+506`.
  cri("506", "CR", "CRI", "Costa Rica"),

  /// Cuba — `CUB`, dial code `+53`.
  cub("53", "CU", "CUB", "Cuba"),

  /// Curaçao — `CUW`, dial code `+599`.
  cuw("599", "CW", "CUW", "Curaçao"),

  /// Christmas Island — `CXR`, dial code `+61`.
  cxr("61", "CX", "CXR", "Christmas Island"),

  /// Cayman Islands — `CYM`, dial code `+1`.
  cym("1", "KY", "CYM", "Cayman Islands"),

  /// Cyprus — `CYP`, dial code `+357`.
  cyp("357", "CY", "CYP", "Cyprus"),

  /// Czech Republic — `CZE`, dial code `+420`.
  cze("420", "CZ", "CZE", "Czech Republic"),

  /// Germany — `DEU`, dial code `+49`.
  deu("49", "DE", "DEU", "Germany"),

  /// Djibouti — `DJI`, dial code `+253`.
  dji("253", "DJ", "DJI", "Djibouti"),

  /// Dominica — `DMA`, dial code `+1`.
  dma("1", "DM", "DMA", "Dominica"),

  /// Denmark — `DNK`, dial code `+45`.
  dnk("45", "DK", "DNK", "Denmark"),

  /// Dominican Republic — `DOM`, dial code `+1`.
  dom("1", "DO", "DOM", "Dominican Republic"),

  /// Algeria — `DZA`, dial code `+213`.
  dza("213", "DZ", "DZA", "Algeria"),

  /// Ecuador — `ECU`, dial code `+593`.
  ecu("593", "EC", "ECU", "Ecuador"),

  /// Egypt — `EGY`, dial code `+20`.
  egy("20", "EG", "EGY", "Egypt"),

  /// Eritrea — `ERI`, dial code `+291`.
  eri("291", "ER", "ERI", "Eritrea"),

  /// Western Sahara — `ESH`, dial code `+212`.
  esh("212", "EH", "ESH", "Western Sahara"),

  /// Spain — `ESP`, dial code `+34`.
  esp("34", "ES", "ESP", "Spain"),

  /// Estonia — `EST`, dial code `+372`.
  est("372", "EE", "EST", "Estonia"),

  /// Ethiopia — `ETH`, dial code `+251`.
  eth("251", "ET", "ETH", "Ethiopia"),

  /// Finland — `FIN`, dial code `+358`.
  fin("358", "FI", "FIN", "Finland"),

  /// Fiji — `FJI`, dial code `+679`.
  fji("679", "FJ", "FJI", "Fiji"),

  /// Falkland Islands [Islas Malvinas] — `FLK`, dial code `+500`.
  flk("500", "FK", "FLK", "Falkland Islands [Islas Malvinas]"),

  /// France — `FRA`, dial code `+33`.
  fra("33", "FR", "FRA", "France"),

  /// Faroe Islands — `FRO`, dial code `+298`.
  fro("298", "FO", "FRO", "Faroe Islands"),

  /// Micronesia — `FSM`, dial code `+691`.
  fsm("691", "FM", "FSM", "Micronesia"),

  /// Gabon — `GAB`, dial code `+241`.
  gab("241", "GA", "GAB", "Gabon"),

  /// United Kingdom — `GBR`, dial code `+44`.
  gbr("44", "GB", "GBR", "United Kingdom"),

  /// Georgia — `GEO`, dial code `+995`.
  geo("995", "GE", "GEO", "Georgia"),

  /// Guernsey — `GGY`, dial code `+44`.
  ggy("44", "GG", "GGY", "Guernsey"),

  /// Ghana — `GHA`, dial code `+233`.
  gha("233", "GH", "GHA", "Ghana"),

  /// Gibraltar — `GIB`, dial code `+350`.
  gib("350", "GI", "GIB", "Gibraltar"),

  /// Guinea Conakry — `GIN`, dial code `+224`.
  gin("224", "GN", "GIN", "Guinea Conakry"),

  /// Guadeloupe — `GLP`, dial code `+590`.
  glp("590", "GP", "GLP", "Guadeloupe"),

  /// Gambia — `GMB`, dial code `+220`.
  gmb("220", "GM", "GMB", "Gambia"),

  /// Guinea-Bissau — `GNB`, dial code `+245`.
  gnb("245", "GW", "GNB", "Guinea-Bissau"),

  /// Equatorial Guinea — `GNQ`, dial code `+240`.
  gnq("240", "GQ", "GNQ", "Equatorial Guinea"),

  /// Greece — `GRC`, dial code `+30`.
  grc("30", "GR", "GRC", "Greece"),

  /// Grenada — `GRD`, dial code `+1`.
  grd("1", "GD", "GRD", "Grenada"),

  /// Greenland — `GRL`, dial code `+299`.
  grl("299", "GL", "GRL", "Greenland"),

  /// Guatemala — `GTM`, dial code `+502`.
  gtm("502", "GT", "GTM", "Guatemala"),

  /// French Guiana — `GUF`, dial code `+594`.
  guf("594", "GF", "GUF", "French Guiana"),

  /// Guam — `GUM`, dial code `+1`.
  gum("1", "GU", "GUM", "Guam"),

  /// Guyana — `GUY`, dial code `+592`.
  guy("592", "GY", "GUY", "Guyana"),

  /// Hong Kong — `HKG`, dial code `+852`.
  hkg("852", "HK", "HKG", "Hong Kong"),

  /// Heard Island and McDonald Islands — `HMD`, dial code `+672`.
  hmd("672", "HM", "HMD", "Heard Island and McDonald Islands"),

  /// Honduras — `HND`, dial code `+504`.
  hnd("504", "HN", "HND", "Honduras"),

  /// Croatia — `HRV`, dial code `+385`.
  hrv("385", "HR", "HRV", "Croatia"),

  /// Haiti — `HTI`, dial code `+509`.
  hti("509", "HT", "HTI", "Haiti"),

  /// Hungary — `HUN`, dial code `+36`.
  hun("36", "HU", "HUN", "Hungary"),

  /// Indonesia — `IDN`, dial code `+62`.
  idn("62", "ID", "IDN", "Indonesia"),

  /// Isle of Man — `IMN`, dial code `+44`.
  imn("44", "IM", "IMN", "Isle of Man"),

  /// India — `IND`, dial code `+91`.
  ind("91", "IN", "IND", "India"),

  /// British Indian Ocean Territory — `IOT`, dial code `+246`.
  iot("246", "IO", "IOT", "British Indian Ocean Territory"),

  /// Ireland — `IRL`, dial code `+353`.
  irl("353", "IE", "IRL", "Ireland"),

  /// Iran — `IRN`, dial code `+98`.
  irn("98", "IR", "IRN", "Iran"),

  /// Iraq — `IRQ`, dial code `+964`.
  irq("964", "IQ", "IRQ", "Iraq"),

  /// Iceland — `ISL`, dial code `+354`.
  isl("354", "IS", "ISL", "Iceland"),

  /// Israel — `ISR`, dial code `+972`.
  isr("972", "IL", "ISR", "Israel"),

  /// Italy — `ITA`, dial code `+39`.
  ita("39", "IT", "ITA", "Italy"),

  /// Jamaica — `JAM`, dial code `+1`.
  jam("1", "JM", "JAM", "Jamaica"),

  /// Jersey — `JEY`, dial code `+44`.
  jey("44", "JE", "JEY", "Jersey"),

  /// Jordan — `JOR`, dial code `+962`.
  jor("962", "JO", "JOR", "Jordan"),

  /// Japan — `JPN`, dial code `+81`.
  jpn("81", "JP", "JPN", "Japan"),

  /// Kazakhstan — `KAZ`, dial code `+7`.
  kaz("7", "KZ", "KAZ", "Kazakhstan"),

  /// Kenya — `KEN`, dial code `+254`.
  ken("254", "KE", "KEN", "Kenya"),

  /// Kyrgyzstan — `KGZ`, dial code `+996`.
  kgz("996", "KG", "KGZ", "Kyrgyzstan"),

  /// Cambodia — `KHM`, dial code `+855`.
  khm("855", "KH", "KHM", "Cambodia"),

  /// Kiribati — `KIR`, dial code `+686`.
  kir("686", "KI", "KIR", "Kiribati"),

  /// St. Kitts — `KNA`, dial code `+1`.
  kna("1", "KN", "KNA", "St. Kitts"),

  /// South Korea — `KOR`, dial code `+82`.
  kor("82", "KR", "KOR", "South Korea"),

  /// Kuwait — `KWT`, dial code `+965`.
  kwt("965", "KW", "KWT", "Kuwait"),

  /// Laos — `LAO`, dial code `+856`.
  lao("856", "LA", "LAO", "Laos"),

  /// Lebanon — `LBN`, dial code `+961`.
  lbn("961", "LB", "LBN", "Lebanon"),

  /// Liberia — `LBR`, dial code `+231`.
  lbr("231", "LR", "LBR", "Liberia"),

  /// Libya — `LBY`, dial code `+218`.
  lby("218", "LY", "LBY", "Libya"),

  /// St. Lucia — `LCA`, dial code `+1`.
  lca("1", "LC", "LCA", "St. Lucia"),

  /// Liechtenstein — `LIE`, dial code `+423`.
  lie("423", "LI", "LIE", "Liechtenstein"),

  /// Sri Lanka — `LKA`, dial code `+94`.
  lka("94", "LK", "LKA", "Sri Lanka"),

  /// Lesotho — `LSO`, dial code `+266`.
  lso("266", "LS", "LSO", "Lesotho"),

  /// Lithuania — `LTU`, dial code `+370`.
  ltu("370", "LT", "LTU", "Lithuania"),

  /// Luxembourg — `LUX`, dial code `+352`.
  lux("352", "LU", "LUX", "Luxembourg"),

  /// Latvia — `LVA`, dial code `+371`.
  lva("371", "LV", "LVA", "Latvia"),

  /// Macau — `MAC`, dial code `+853`.
  mac("853", "MO", "MAC", "Macau"),

  /// Saint Martin — `MAF`, dial code `+590`.
  maf("590", "MF", "MAF", "Saint Martin"),

  /// Morocco — `MAR`, dial code `+212`.
  mar("212", "MA", "MAR", "Morocco"),

  /// Monaco — `MCO`, dial code `+377`.
  mco("377", "MC", "MCO", "Monaco"),

  /// Moldova — `MDA`, dial code `+373`.
  mda("373", "MD", "MDA", "Moldova"),

  /// Madagascar — `MDG`, dial code `+261`.
  mdg("261", "MG", "MDG", "Madagascar"),

  /// Maldives — `MDV`, dial code `+960`.
  mdv("960", "MV", "MDV", "Maldives"),

  /// Mexico — `MEX`, dial code `+52`.
  mex("52", "MX", "MEX", "Mexico"),

  /// Marshall Islands — `MHL`, dial code `+692`.
  mhl("692", "MH", "MHL", "Marshall Islands"),

  /// Macedonia — `MKD`, dial code `+389`.
  mkd("389", "MK", "MKD", "Macedonia"),

  /// Mali — `MLI`, dial code `+223`.
  mli("223", "ML", "MLI", "Mali"),

  /// Malta — `MLT`, dial code `+356`.
  mlt("356", "MT", "MLT", "Malta"),

  /// Myanmar [Burma] — `MMR`, dial code `+95`.
  mmr("95", "MM", "MMR", "Myanmar [Burma]"),

  /// Montenegro — `MNE`, dial code `+382`.
  mne("382", "ME", "MNE", "Montenegro"),

  /// Mongolia — `MNG`, dial code `+976`.
  mng("976", "MN", "MNG", "Mongolia"),

  /// Northern Mariana Islands — `MNP`, dial code `+1`.
  mnp("1", "MP", "MNP", "Northern Mariana Islands"),

  /// Mozambique — `MOZ`, dial code `+258`.
  moz("258", "MZ", "MOZ", "Mozambique"),

  /// Mauritania — `MRT`, dial code `+222`.
  mrt("222", "MR", "MRT", "Mauritania"),

  /// Montserrat — `MSR`, dial code `+1`.
  msr("1", "MS", "MSR", "Montserrat"),

  /// Martinique — `MTQ`, dial code `+596`.
  mtq("596", "MQ", "MTQ", "Martinique"),

  /// Mauritius — `MUS`, dial code `+230`.
  mus("230", "MU", "MUS", "Mauritius"),

  /// Malawi — `MWI`, dial code `+265`.
  mwi("265", "MW", "MWI", "Malawi"),

  /// Malaysia — `MYS`, dial code `+60`.
  mys("60", "MY", "MYS", "Malaysia"),

  /// Mayotte — `MYT`, dial code `+262`.
  myt("262", "YT", "MYT", "Mayotte"),

  /// Namibia — `NAM`, dial code `+264`.
  nam("264", "NA", "NAM", "Namibia"),

  /// New Caledonia — `NCL`, dial code `+687`.
  ncl("687", "NC", "NCL", "New Caledonia"),

  /// Niger — `NER`, dial code `+227`.
  ner("227", "NE", "NER", "Niger"),

  /// Norfolk Island — `NFK`, dial code `+672`.
  nfk("672", "NF", "NFK", "Norfolk Island"),

  /// Nigeria — `NGA`, dial code `+234`.
  nga("234", "NG", "NGA", "Nigeria"),

  /// Nicaragua — `NIC`, dial code `+505`.
  nic("505", "NI", "NIC", "Nicaragua"),

  /// Niue — `NIU`, dial code `+683`.
  niu("683", "NU", "NIU", "Niue"),

  /// Netherlands — `NLD`, dial code `+31`.
  nld("31", "NL", "NLD", "Netherlands"),

  /// Norway — `NOR`, dial code `+47`.
  nor("47", "NO", "NOR", "Norway"),

  /// Nepal — `NPL`, dial code `+977`.
  npl("977", "NP", "NPL", "Nepal"),

  /// Nauru — `NRU`, dial code `+674`.
  nru("674", "NR", "NRU", "Nauru"),

  /// New Zealand — `NZL`, dial code `+64`.
  nzl("64", "NZ", "NZL", "New Zealand"),

  /// Oman — `OMN`, dial code `+968`.
  omn("968", "OM", "OMN", "Oman"),

  /// Pakistan — `PAK`, dial code `+92`.
  pak("92", "PK", "PAK", "Pakistan"),

  /// Panama — `PAN`, dial code `+507`.
  pan("507", "PA", "PAN", "Panama"),

  /// Peru — `PER`, dial code `+51`.
  per("51", "PE", "PER", "Peru"),

  /// Philippines — `PHL`, dial code `+63`.
  phl("63", "PH", "PHL", "Philippines"),

  /// Palau — `PLW`, dial code `+680`.
  plw("680", "PW", "PLW", "Palau"),

  /// Papua New Guinea — `PNG`, dial code `+675`.
  png("675", "PG", "PNG", "Papua New Guinea"),

  /// Poland — `POL`, dial code `+48`.
  pol("48", "PL", "POL", "Poland"),

  /// Puerto Rico — `PRI`, dial code `+1`.
  pri("1", "PR", "PRI", "Puerto Rico"),

  /// North Korea — `PRK`, dial code `+850`.
  prk("850", "KP", "PRK", "North Korea"),

  /// Portugal — `PRT`, dial code `+351`.
  prt("351", "PT", "PRT", "Portugal"),

  /// Paraguay — `PRY`, dial code `+595`.
  pry("595", "PY", "PRY", "Paraguay"),

  /// Palestinian Territories — `PSE`, dial code `+970`.
  pse("970", "PS", "PSE", "Palestinian Territories"),

  /// French Polynesia — `PYF`, dial code `+689`.
  pyf("689", "PF", "PYF", "French Polynesia"),

  /// Qatar — `QAT`, dial code `+974`.
  qat("974", "QA", "QAT", "Qatar"),

  /// Réunion — `REU`, dial code `+262`.
  reu("262", "RE", "REU", "Réunion"),

  /// Romania — `ROU`, dial code `+40`.
  rou("40", "RO", "ROU", "Romania"),

  /// Russia — `RUS`, dial code `+7`.
  rus("7", "RU", "RUS", "Russia"),

  /// Rwanda — `RWA`, dial code `+250`.
  rwa("250", "RW", "RWA", "Rwanda"),

  /// Saudi Arabia — `SAU`, dial code `+966`.
  sau("966", "SA", "SAU", "Saudi Arabia"),

  /// Sudan — `SDN`, dial code `+249`.
  sdn("249", "SD", "SDN", "Sudan"),

  /// Senegal — `SEN`, dial code `+221`.
  sen("221", "SN", "SEN", "Senegal"),

  /// Singapore — `SGP`, dial code `+65`.
  sgp("65", "SG", "SGP", "Singapore"),

  /// South Georgia and the South Sandwich Islands — `SGS`, dial code `+500`.
  sgs("500", "GS", "SGS", "South Georgia and the South Sandwich Islands"),

  /// Saint Helena — `SHN`, dial code `+290`.
  shn("290", "SH", "SHN", "Saint Helena"),

  /// Svalbard and Jan Mayen — `SJM`, dial code `+47`.
  sjm("47", "SJ", "SJM", "Svalbard and Jan Mayen"),

  /// Solomon Islands — `SLB`, dial code `+677`.
  slb("677", "SB", "SLB", "Solomon Islands"),

  /// Sierra Leone — `SLE`, dial code `+232`.
  sle("232", "SL", "SLE", "Sierra Leone"),

  /// El Salvador — `SLV`, dial code `+503`.
  slv("503", "SV", "SLV", "El Salvador"),

  /// San Marino — `SMR`, dial code `+378`.
  smr("378", "SM", "SMR", "San Marino"),

  /// Somalia — `SOM`, dial code `+252`.
  som("252", "SO", "SOM", "Somalia"),

  /// Saint Pierre and Miquelon — `SPM`, dial code `+508`.
  spm("508", "PM", "SPM", "Saint Pierre and Miquelon"),

  /// Serbia — `SRB`, dial code `+381`.
  srb("381", "RS", "SRB", "Serbia"),

  /// South Sudan — `SSD`, dial code `+211`.
  ssd("211", "SS", "SSD", "South Sudan"),

  /// São Tomé and Príncipe — `STP`, dial code `+239`.
  stp("239", "ST", "STP", "São Tomé and Príncipe"),

  /// Suriname — `SUR`, dial code `+597`.
  sur("597", "SR", "SUR", "Suriname"),

  /// Slovakia — `SVK`, dial code `+421`.
  svk("421", "SK", "SVK", "Slovakia"),

  /// Slovenia — `SVN`, dial code `+386`.
  svn("386", "SI", "SVN", "Slovenia"),

  /// Sweden — `SWE`, dial code `+46`.
  swe("46", "SE", "SWE", "Sweden"),

  /// Swaziland — `SWZ`, dial code `+268`.
  swz("268", "SZ", "SWZ", "Swaziland"),

  /// Sint Maarten — `SXM`, dial code `+1`.
  sxm("1", "SX", "SXM", "Sint Maarten"),

  /// Seychelles — `SYC`, dial code `+248`.
  syc("248", "SC", "SYC", "Seychelles"),

  /// Syria — `SYR`, dial code `+963`.
  syr("963", "SY", "SYR", "Syria"),

  /// Turks and Caicos Islands — `TCA`, dial code `+1`.
  tca("1", "TC", "TCA", "Turks and Caicos Islands"),

  /// Chad — `TCD`, dial code `+235`.
  tcd("235", "TD", "TCD", "Chad"),

  /// Togo — `TGO`, dial code `+228`.
  tgo("228", "TG", "TGO", "Togo"),

  /// Thailand — `THA`, dial code `+66`.
  tha("66", "TH", "THA", "Thailand"),

  /// Tajikistan — `TJK`, dial code `+992`.
  tjk("992", "TJ", "TJK", "Tajikistan"),

  /// Tokelau — `TKL`, dial code `+690`.
  tkl("690", "TK", "TKL", "Tokelau"),

  /// Turkmenistan — `TKM`, dial code `+993`.
  tkm("993", "TM", "TKM", "Turkmenistan"),

  /// East Timor — `TLS`, dial code `+670`.
  tls("670", "TL", "TLS", "East Timor"),

  /// Tonga — `TON`, dial code `+676`.
  ton("676", "TO", "TON", "Tonga"),

  /// Trinidad/Tobago — `TTO`, dial code `+1`.
  tto("1", "TT", "TTO", "Trinidad/Tobago"),

  /// Tunisia — `TUN`, dial code `+216`.
  tun("216", "TN", "TUN", "Tunisia"),

  /// Turkey — `TUR`, dial code `+90`.
  tur("90", "TR", "TUR", "Turkey"),

  /// Tuvalu — `TUV`, dial code `+688`.
  tuv("688", "TV", "TUV", "Tuvalu"),

  /// Taiwan — `TWN`, dial code `+886`.
  twn("886", "TW", "TWN", "Taiwan"),

  /// Tanzania — `TZA`, dial code `+255`.
  tza("255", "TZ", "TZA", "Tanzania"),

  /// Uganda — `UGA`, dial code `+256`.
  uga("256", "UG", "UGA", "Uganda"),

  /// Ukraine — `UKR`, dial code `+380`.
  ukr("380", "UA", "UKR", "Ukraine"),

  /// Uruguay — `URY`, dial code `+598`.
  ury("598", "UY", "URY", "Uruguay"),

  /// United States — `USA`, dial code `+1`.
  usa("1", "US", "USA", "United States"),

  /// Uzbekistan — `UZB`, dial code `+998`.
  uzb("998", "UZ", "UZB", "Uzbekistan"),

  /// Vatican City — `VAT`, dial code `+379`.
  vat("379", "VA", "VAT", "Vatican City"),

  /// St. Vincent — `VCT`, dial code `+1`.
  vct("1", "VC", "VCT", "St. Vincent"),

  /// Venezuela — `VEN`, dial code `+58`.
  ven("58", "VE", "VEN", "Venezuela"),

  /// British Virgin Islands — `VGB`, dial code `+1`.
  vgb("1", "VG", "VGB", "British Virgin Islands"),

  /// U.S. Virgin Islands — `VIR`, dial code `+1`.
  vir("1", "VI", "VIR", "U.S. Virgin Islands"),

  /// Vietnam — `VNM`, dial code `+84`.
  vnm("84", "VN", "VNM", "Vietnam"),

  /// Vanuatu — `VUT`, dial code `+678`.
  vut("678", "VU", "VUT", "Vanuatu"),

  /// Wallis and Futuna — `WLF`, dial code `+681`.
  wlf("681", "WF", "WLF", "Wallis and Futuna"),

  /// Samoa — `WSM`, dial code `+685`.
  wsm("685", "WS", "WSM", "Samoa"),

  /// Kosovo — `XKX`, dial code `+383`.
  xkx("383", "XK", "XKX", "Kosovo"),

  /// Yemen — `YEM`, dial code `+967`.
  yem("967", "YE", "YEM", "Yemen"),

  /// South Africa — `ZAF`, dial code `+27`.
  zaf("27", "ZA", "ZAF", "South Africa"),

  /// Zambia — `ZMB`, dial code `+260`.
  zmb("260", "ZM", "ZMB", "Zambia"),

  /// Zimbabwe — `ZWE`, dial code `+263`.
  zwe("263", "ZW", "ZWE", "Zimbabwe"),
  ;

  const Country(this.dialCode, this.alpha2, this.alpha3, this.countryName);

  /// ITU-T country calling code, without `+`. Not unique: see the enum note.
  final String dialCode;

  /// ISO 3166-1 alpha-2. Present for flags and locales only.
  final String alpha2;

  /// ISO 3166-1 alpha-3. The code this SDK accepts and stores.
  final String alpha3;

  /// English name, for pickers. Not part of any key.
  final String countryName;

  static final Map<String, Country> _byAlpha3 = <String, Country>{
    for (final Country c in Country.values) c.alpha3: c,
  };

  /// The country with this ISO 3166-1 alpha-3 code, case-insensitively, or null.
  static Country? fromAlpha3(String alpha3) => _byAlpha3[alpha3
      .replaceAll(RegExp(r'^[ \t\n\x0B\x0C\r]+|[ \t\n\x0B\x0C\r]+$'), '')
      .toUpperCase()];
}
