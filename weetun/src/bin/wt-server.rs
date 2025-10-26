use std::{collections::HashMap, net::{Ipv4Addr, SocketAddr, SocketAddrV4}, process::Command, sync::Arc, time::{Duration, Instant}};
use socket2::{Domain, SockAddr, Type};
use tokio::{io::{AsyncReadExt, AsyncWriteExt}, net::UdpSocket, sync::Mutex};
use tokio_tun::Tun;

const CONN_TIMEOUT: Duration = Duration::from_secs(1 * 60); // 1 hour

struct ActiveConnection {
    last_time: Instant,
}

#[tokio::main]
async fn main() {
    let args = std::env::args().collect::<Vec<_>>();

    let tun = Tun::builder()
        .name("tunS")
        .packet_info()
        .up()
        .close_on_exec()
        .address(Ipv4Addr::new(10, 6, 6, 1))
        .netmask(Ipv4Addr::new(255, 255, 255, 0))
        .mtu(1280)
        .build()
        .unwrap()
        .pop()
        .unwrap();

    println!("tun created: {:?}", tun.name());

    std::fs::write(format!("/proc/sys/net/ipv6/conf/{}/disable_ipv6", tun.name()), "1").unwrap();

    Command::new("iptables")
        .args(["-I", "FORWARD", "-i", tun.name(), "-j", "ACCEPT"])
        .output().unwrap();

    // iptables -t nat -I POSTROUTING -s 10.6.6.0/24 -o wgcal -j MASQUERADE
    Command::new("iptables")
        .args(["-t", "nat", "-I", "POSTROUTING", "-s", "10.6.6.0/24", "-o", "eth0", "-j", "MASQUERADE"])
        .output().unwrap();

    let (mut tun_reader, mut tun_writer) = tokio::io::split(tun);

    // listen udp 
    let udp_listener = Arc::new(UdpSocket::bind("0.0.0.0:29292").await.unwrap());
    let udp_listener_clone = udp_listener.clone();
    let active_connections = Arc::new(Mutex::new(HashMap::new()));
    let active_connections_clone = active_connections.clone();
    tokio::spawn(async move {
        let mut buf = [0u8; 2048];
        loop {
            let (n, addr) = udp_listener_clone.recv_from(&mut buf).await.unwrap();
            active_connections_clone.lock().await.insert(addr, ActiveConnection {
                last_time: Instant::now()
            });

            for i in 0..n {
                buf[i] ^= 0x55;
            }

            match tun_writer.write(&buf[..n]).await {
                Ok(_) => println!("wrote {} bytes from {:?} to tun", n, addr),
                Err(e) => println!("FAILED To write {} bytes from {:?} to tun: {:?}", n, addr, e)
            }
        }
    });

    // reader
    let mut buf = [0u8; 2048];
    loop {
        let n = tun_reader.read(&mut buf).await.unwrap();
        println!("reading {} bytes: {:?}", n, &buf[..n]);

        // send it to every active conn 
        let map = active_connections.lock().await;
        for (addr, conn_info) in map.iter() {
            if Instant::now().duration_since(conn_info.last_time) > CONN_TIMEOUT {
                continue;
            }

            for i in 0..n {
                buf[i] ^= 0x55;
            }

            match udp_listener.send_to(&buf[..n], addr).await {
                Ok(n) => println!("sent {} bytes to {:?}", n, addr),
                Err(e) => println!("FAILED To send {} bytes to {:?}: {:?}", n, addr, e)
            }
        }
    }
}

