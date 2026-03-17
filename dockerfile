FROM  alpine:latest AS build

ARG VERSION=1.29.6
ARG PCRE_VERSION=10.47
ARG ZLIB_VERSION=1.3.2

RUN apk add --no-cache --virtual .build-deps linux-headers build-base pcre-dev wget zlib-dev

RUN  wget -q http://nginx.org/download/nginx-${VERSION}.tar.gz && \
  wget  https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${PCRE_VERSION}/pcre2-${PCRE_VERSION}.tar.gz && \
  wget -q http://zlib.net/zlib-$ZLIB_VERSION.tar.gz && \
  tar -xf nginx-${VERSION}.tar.gz -C /tmp && \
  tar -xf pcre2-${PCRE_VERSION}.tar.gz -C /tmp && \
  tar -xf zlib-${ZLIB_VERSION}.tar.gz -C /tmp

WORKDIR /tmp/nginx-${VERSION}

RUN ./configure \ 
  --with-http_sub_module \
  --with-ld-opt="-static" \
  --with-pcre=/tmp/pcre2-${PCRE_VERSION} \
  --with-zlib=/tmp/zlib-${ZLIB_VERSION} && \
  make install 

FROM scratch 

COPY --from=build /etc/passwd /etc/group /etc/
COPY --from=build /usr/local/nginx /usr/local/nginx
COPY public/ /usr/local/nginx/html/
COPY nginx.conf /usr/local/nginx/conf/


ENTRYPOINT ["/usr/local/nginx/sbin/nginx"]
CMD ["-e", "/tmp/nginx/error.log", "-g", "daemon off;"]
