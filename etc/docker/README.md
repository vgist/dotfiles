/etc/docker/daemon.json

    {
        "experimental": true,
        "ip6tables": true
    }

or

    {
        "ipv6": true,
        "fixed-cidr-v6": "fd00:1::/80",
        "experimental": true,
        "ip6tables": true
    }

docker ipv6

    sudo docker network create -d bridge --subnet 172.10.0.0/24 --ipv6 --subnet=fd00:2::/80 yourname
    sudo docker run --rm --network yourname -it busybox ping -6 -c4 www.google.com

docker compose file

    services:
        nginx:
            image: nginx
            networks:
            local:
            restart: always

    networks:
        local:
            name: youname
            external: true
