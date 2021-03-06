error {
    IPv4OptionsNotSupported,
    IPv4IncorrectVersion,
    IPv4ChecksumError
}
#include <core.p4>

typedef bit<4> PortId;
struct InControl {
    PortId inputPort;
}

struct OutControl {
    PortId outputPort;
}

parser Parser<H>(packet_in b, out H parsedHeaders);
control Pipe<H>(inout H headers, in error parseError, in InControl inCtrl, out OutControl outCtrl);
control Deparser<H>(inout H outputHeaders, packet_out b);
package VSS<H>(Parser<H> p, Pipe<H> map, Deparser<H> d);
extern Ck16 {
    Ck16();
    void clear();
    void update<T>(in T data);
    bit<16> get();
}

typedef bit<48> EthernetAddress;
typedef bit<32> IPv4Address;
header Ethernet_h {
    EthernetAddress dstAddr;
    EthernetAddress srcAddr;
    bit<16>         etherType;
}

header Ipv4_h {
    bit<4>      version;
    bit<4>      ihl;
    bit<8>      diffserv;
    bit<16>     totalLen;
    bit<16>     identification;
    bit<3>      flags;
    bit<13>     fragOffset;
    bit<8>      ttl;
    bit<8>      protocol;
    bit<16>     hdrChecksum;
    IPv4Address srcAddr;
    IPv4Address dstAddr;
}

struct Parsed_packet {
    Ethernet_h ethernet;
    Ipv4_h     ip;
}

parser TopParser(packet_in b, out Parsed_packet p) {
    bit<16> tmp_3;
    bool tmp_4;
    bool tmp_5;
    @name("TopParser.ck") Ck16() ck;
    state start {
        b.extract<Ethernet_h>(p.ethernet);
        transition select(p.ethernet.etherType) {
            16w0x800: parse_ipv4;
            default: noMatch;
        }
    }
    state parse_ipv4 {
        b.extract<Ipv4_h>(p.ip);
        verify(p.ip.version == 4w4, error.IPv4IncorrectVersion);
        verify(p.ip.ihl == 4w5, error.IPv4OptionsNotSupported);
        ck.clear();
        ck.update<Ipv4_h>(p.ip);
        tmp_3 = ck.get();
        tmp_4 = tmp_3 == 16w0;
        tmp_5 = tmp_4;
        verify(tmp_5, error.IPv4ChecksumError);
        transition accept;
    }
    state noMatch {
        verify(false, error.NoMatch);
        transition reject;
    }
}

control TopPipe(inout Parsed_packet headers, in error parseError, in InControl inCtrl, out OutControl outCtrl) {
    IPv4Address nextHop;
    bool hasReturned_0;
    @name(".NoAction") action NoAction_0() {
    }
    @name("TopPipe.Drop_action") action Drop_action_0() {
        outCtrl.outputPort = 4w0xf;
    }
    @name("TopPipe.Drop_action") action Drop_action_4() {
        outCtrl.outputPort = 4w0xf;
    }
    @name("TopPipe.Drop_action") action Drop_action_5() {
        outCtrl.outputPort = 4w0xf;
    }
    @name("TopPipe.Drop_action") action Drop_action_6() {
        outCtrl.outputPort = 4w0xf;
    }
    @name("TopPipe.Set_nhop") action Set_nhop_0(IPv4Address ipv4_dest, PortId port) {
        nextHop = ipv4_dest;
        headers.ip.ttl = headers.ip.ttl + 8w255;
        outCtrl.outputPort = port;
    }
    @name("TopPipe.ipv4_match") table ipv4_match {
        key = {
            headers.ip.dstAddr: lpm @name("headers.ip.dstAddr") ;
        }
        actions = {
            Drop_action_0();
            Set_nhop_0();
        }
        size = 1024;
        default_action = Drop_action_0();
    }
    @name("TopPipe.Send_to_cpu") action Send_to_cpu_0() {
        outCtrl.outputPort = 4w0xe;
    }
    @name("TopPipe.check_ttl") table check_ttl {
        key = {
            headers.ip.ttl: exact @name("headers.ip.ttl") ;
        }
        actions = {
            Send_to_cpu_0();
            NoAction_0();
        }
        const default_action = NoAction_0();
    }
    @name("TopPipe.Set_dmac") action Set_dmac_0(EthernetAddress dmac) {
        headers.ethernet.dstAddr = dmac;
    }
    @name("TopPipe.dmac") table dmac_1 {
        key = {
            nextHop: exact @name("nextHop") ;
        }
        actions = {
            Drop_action_4();
            Set_dmac_0();
        }
        size = 1024;
        default_action = Drop_action_4();
    }
    @name("TopPipe.Set_smac") action Set_smac_0(EthernetAddress smac) {
        headers.ethernet.srcAddr = smac;
    }
    @name("TopPipe.smac") table smac_1 {
        key = {
            outCtrl.outputPort: exact @name("outCtrl.outputPort") ;
        }
        actions = {
            Drop_action_5();
            Set_smac_0();
        }
        size = 16;
        default_action = Drop_action_5();
    }
    @hidden action act() {
        hasReturned_0 = true;
    }
    @hidden action act_0() {
        hasReturned_0 = false;
    }
    @hidden action act_1() {
        hasReturned_0 = true;
    }
    @hidden action act_2() {
        hasReturned_0 = true;
    }
    @hidden action act_3() {
        hasReturned_0 = true;
    }
    @hidden table tbl_act {
        actions = {
            act_0();
        }
        const default_action = act_0();
    }
    @hidden table tbl_Drop_action {
        actions = {
            Drop_action_6();
        }
        const default_action = Drop_action_6();
    }
    @hidden table tbl_act_0 {
        actions = {
            act();
        }
        const default_action = act();
    }
    @hidden table tbl_act_1 {
        actions = {
            act_1();
        }
        const default_action = act_1();
    }
    @hidden table tbl_act_2 {
        actions = {
            act_2();
        }
        const default_action = act_2();
    }
    @hidden table tbl_act_3 {
        actions = {
            act_3();
        }
        const default_action = act_3();
    }
    apply {
        tbl_act.apply();
        if (parseError != error.NoError) {
            tbl_Drop_action.apply();
            tbl_act_0.apply();
        }
        if (!hasReturned_0) {
            ipv4_match.apply();
            if (outCtrl.outputPort == 4w0xf) 
                tbl_act_1.apply();
        }
        if (!hasReturned_0) {
            check_ttl.apply();
            if (outCtrl.outputPort == 4w0xe) 
                tbl_act_2.apply();
        }
        if (!hasReturned_0) {
            dmac_1.apply();
            if (outCtrl.outputPort == 4w0xf) 
                tbl_act_3.apply();
        }
        if (!hasReturned_0) 
            smac_1.apply();
    }
}

control TopDeparser(inout Parsed_packet p, packet_out b) {
    bit<16> tmp_6;
    @name("TopDeparser.ck") Ck16() ck_2;
    @hidden action act_4() {
        ck_2.clear();
        p.ip.hdrChecksum = 16w0;
        ck_2.update<Ipv4_h>(p.ip);
        tmp_6 = ck_2.get();
        p.ip.hdrChecksum = tmp_6;
    }
    @hidden action act_5() {
        b.emit<Ethernet_h>(p.ethernet);
    }
    @hidden action act_6() {
        b.emit<Ipv4_h>(p.ip);
    }
    @hidden table tbl_act_4 {
        actions = {
            act_5();
        }
        const default_action = act_5();
    }
    @hidden table tbl_act_5 {
        actions = {
            act_4();
        }
        const default_action = act_4();
    }
    @hidden table tbl_act_6 {
        actions = {
            act_6();
        }
        const default_action = act_6();
    }
    apply {
        tbl_act_4.apply();
        if (p.ip.isValid()) {
            tbl_act_5.apply();
        }
        tbl_act_6.apply();
    }
}

VSS<Parsed_packet>(TopParser(), TopPipe(), TopDeparser()) main;

