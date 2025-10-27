sudo systemctl stop NetworkManager.service
sudo systemctl start systemd-networkd.service
sudo nft flush ruleset; sudo nft -f /etc/nftables.conf
sh interfaces.sh
sudo weefi/weetun/target/release/wt-client $SERVER:29292 &
