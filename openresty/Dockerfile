FROM openresty/openresty:1.25.3.1-alpine

RUN apk add --no-cache zlib

COPY lua/ /etc/openresty/lua/
COPY nginx/nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
COPY nginx/conf/ /usr/local/openresty/nginx/conf/conf/

EXPOSE 8080

CMD ["/usr/local/openresty/bin/openresty", "-g", "daemon off;"]
