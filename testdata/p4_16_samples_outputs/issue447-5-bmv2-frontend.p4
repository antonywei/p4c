#include <core.p4>
#include <v1model.p4>

header S {
    bit<32> size;
}

header H {
    varbit<32> var;
}

struct Parsed_packet {
    S s1;
    H h1;
    H h2;
}

struct Metadata {
}

parser parserI(packet_in pkt, out Parsed_packet hdr, inout Metadata meta, inout standard_metadata_t stdmeta) {
    H tmp;
    bit<32> tmp_0;
    H tmp_1;
    bit<32> tmp_2;
    state start {
        pkt.extract<S>(hdr.s1);
        tmp_0 = hdr.s1.size;
        pkt.extract<H>(tmp, tmp_0);
        hdr.h1 = tmp;
        tmp_2 = hdr.s1.size;
        pkt.extract<H>(tmp_1, tmp_2);
        hdr.h2 = tmp_1;
        transition accept;
    }
}

control DeparserI(packet_out packet, in Parsed_packet hdr) {
    apply {
        packet.emit<H>(hdr.h1);
        packet.emit<H>(hdr.h2);
    }
}

control ingress(inout Parsed_packet hdr, inout Metadata meta, inout standard_metadata_t stdmeta) {
    varbit<32> s_0;
    apply {
        s_0 = hdr.h1.var;
        hdr.h1.var = hdr.h2.var;
        hdr.h2.var = s_0;
    }
}

control egress(inout Parsed_packet hdr, inout Metadata meta, inout standard_metadata_t stdmeta) {
    apply {
    }
}

control vc(in Parsed_packet hdr, inout Metadata meta) {
    apply {
    }
}

control uc(inout Parsed_packet hdr, inout Metadata meta) {
    apply {
    }
}

V1Switch<Parsed_packet, Metadata>(parserI(), vc(), ingress(), egress(), uc(), DeparserI()) main;