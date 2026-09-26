# WAN-cut acceptance lab

Block WAN and public DNS **before** starting Home.

Required:
- [ ] Home boots;
- [ ] LIFX discovers/controls locally;
- [ ] Hue local control works when qualified;
- [ ] Zigbee detector reports through local coordinator;
- [ ] qualified Shelly devices work locally;
- [ ] local automation executes;
- [ ] DistilBERT either runs locally or explicitly reports unavailable; never cloud-fallback;
- [ ] ex_maude runs locally or governed transitions become unverified; never bypass;
- [ ] restart Home with WAN still absent;
- [ ] restart AP/router and recover identities;
- [ ] unplug/replug Zigbee coordinator and recover without duplicate Things;
- [ ] outbound audit finds no required vendor-cloud destination.
