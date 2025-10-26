use std::{net::{Ipv4Addr, SocketAddr, SocketAddrV4}, process::Command, sync::Arc};
use socket2::{Domain, SockAddr, Type};
use tokio::{io::{AsyncReadExt, AsyncWriteExt}, net::UdpSocket, sync::Mutex};
use tokio_tun::Tun;

const INTERFACES: &[&str] = &[
    // on orbstack test
    "eth0",

    // nils test
    "wlp1s0",

    // tp-link AX, RTL8852AU
    "wlxe0d36283eaa9",
    "wlxe0d3621c0cc6",
    "wlxe0d3621c0276",

    // tp-link AC, RTL8821AU
    "wlx7820510966d2",
    "wlx78205109ad7b",

    // netgear AXE, MT7921U
    "wlx289401b7a3cd",
];

#[tokio::main]
async fn main() {
    let args = std::env::args().collect::<Vec<_>>();
    let server_ip_port: SocketAddr = args[1].parse().unwrap();

    let tun = Tun::builder()
        .name("tunC")
        .packet_info()
        .up()
        .close_on_exec()
        .address(Ipv4Addr::new(10, 6, 6, 2))
        .netmask(Ipv4Addr::new(255, 255, 255, 0))
        .mtu(1280)
        .build()
        .unwrap()
        .pop()
        .unwrap();

    println!("tun created: {:?}", tun.name());

    std::fs::write(format!("/proc/sys/net/ipv6/conf/{}/disable_ipv6", tun.name()), "1").unwrap();

    Command::new("ip")
        .args(["route", "add", "default", "via", "10.6.6.1", "dev", "tunC", "metric", "50"])
        .output().unwrap();

    let (mut tun_reader, tun_writer) = tokio::io::split(tun);
    let tun_writer = Arc::new(Mutex::new(tun_writer));

    // open udp socket for each interface
    let mut udp_sockets = Vec::new();
    for interface in INTERFACES {
        let socket = socket2::Socket::new(Domain::IPV4, Type::DGRAM, None).unwrap();
        match socket.bind_device(Some(interface.as_bytes())) {
            Ok(()) => {}
            Err(e) =>  {
                println!("WARN: interface {} failed: {:?}", interface, e);
                continue;
            },
        }
        socket.set_nonblocking(true).unwrap();
        socket.connect(&server_ip_port.into()).unwrap();

        let socket = Arc::new(UdpSocket::from_std(socket.into()).unwrap());
        println!("udp socket opened for {}: {:?}", interface, socket.local_addr().unwrap());
        udp_sockets.push((interface, socket.clone()));

        let tun_writer_clone = tun_writer.clone();
        tokio::spawn(async move {
            let mut buf = [0u8; 2048];
            loop {
                match socket.recv(&mut buf).await {
                    Ok(n) => {
                        for i in 0..n {
                            buf[i] ^= 0x55;
                        }

                        println!("received {} bytes on interface {}: {:?}", n, interface, &buf[..n]);

                        match tun_writer_clone.lock().await.write(&buf[..n]).await {
                            Ok(_) => println!("wrote {} bytes to tun", n),
                            Err(e) => println!("FAILED To write {} bytes to tun: {:?}", n, e)
                        }
                    }
                    Err(e) => {
                        println!("WARN: socket recv error: {:?}", e);
                    }
                }
            }
        });
    }

    // reader
    let mut buf = [0u8; 2048];
    loop {
        let n = tun_reader.read(&mut buf).await.unwrap();
        println!("reading {} bytes: {:?}", n, &buf[..n]);

        for i in 0..n {
            buf[i] ^= 0x55;
        }

        for (interface_name, socket) in &udp_sockets {
            match socket.send(&buf[..n]).await {
                Ok(n) => {
                    println!("sent {} bytes on interface {}: {:?}", n, interface_name, &buf[..n]);
                }
                Err(e) if e.kind() == std::io::ErrorKind::NetworkUnreachable => {
                    // just try to reconnect as much as we can
                    let _ = socket.connect(server_ip_port).await;
                }
                Err(e) => {
                    println!("WARN: socket send error: {:?}", e);
                }
            }
        }
    }
}

