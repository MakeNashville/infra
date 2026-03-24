FROM moodlehq/moodle-php-apache:8.3

# Download Moodle 4.5 LTS (supported until October 2027)
RUN curl -fsSL -L https://download.moodle.org/download.php/direct/stable405/moodle-latest-405.tgz \
    | tar -xz --strip-components=1 -C /var/www/html \
    && chown -R www-data:www-data /var/www/html \
    && chmod 0770 /var/www/moodledata

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 80

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
