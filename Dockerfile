FROM lscr.io/linuxserver/code-server:latest

# Copy and set up the custom initialization script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
# /init is the standard entrypoint command for LinuxServer.io images
CMD ["/init"]
