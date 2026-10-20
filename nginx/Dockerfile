FROM nginx:alpine

# openssl  - temporary self-signed certificate before the first LE issuance
# gettext  - envsubst for rendering /etc/nginx/templates/*.template
RUN apk add --no-cache openssl gettext

COPY entrypoint.sh /entrypoint.sh
# Strip CRLF (Windows checkout) so the shell script runs inside the container.
RUN tr -d '\r' < /entrypoint.sh > /tmp/entrypoint.sh \
    && mv /tmp/entrypoint.sh /entrypoint.sh \
    && chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
