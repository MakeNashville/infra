#!/bin/bash
set -e

# Generate config.php from environment variables
cat > /var/www/html/config.php <<MOODLECFG
<?php
unset(\$CFG);
global \$CFG;
\$CFG = new stdClass();

\$CFG->dbtype    = 'pgsql';
\$CFG->dblibrary = 'native';
\$CFG->dbhost    = '${MOODLE_DB_HOST:-postgres}';
\$CFG->dbname    = '${MOODLE_DB_NAME:-moodle}';
\$CFG->dbuser    = '${MOODLE_DB_USER:-moodle}';
\$CFG->dbpass    = '${MOODLE_DB_PASSWORD}';
\$CFG->prefix    = 'mdl_';
\$CFG->dboptions = [
    'dbpersist' => false,
    'dbsocket'  => false,
    'dbport'    => '${MOODLE_DB_PORT:-5432}',
];

\$CFG->wwwroot   = '${MOODLE_WWWROOT:-https://learn.makenashville.org}';
\$CFG->dataroot  = '/var/www/moodledata';
\$CFG->admin     = 'admin';

// Redis sessions (DB index 3)
\$CFG->session_handler_class        = '\core\session\redis';
\$CFG->session_redis_host           = '${MOODLE_REDIS_HOST:-redis}';
\$CFG->session_redis_port           = ${MOODLE_REDIS_PORT:-6379};
\$CFG->session_redis_database       = ${MOODLE_REDIS_DB:-3};
\$CFG->session_redis_prefix         = 'mdl_sess_';
\$CFG->session_redis_acquire_lock_timeout = 120;
\$CFG->session_redis_lock_expire    = 7200;
\$CFG->session_redis_lock_retry     = 100;

// Reverse proxy (behind Caddy)
\$CFG->reverseproxy = true;
\$CFG->sslproxy     = true;

require_once(__DIR__ . '/lib/setup.php');
MOODLECFG

chown www-data:www-data /var/www/html/config.php

# Run Moodle install if database tables don't exist yet
if ! sudo -u www-data php /var/www/html/admin/cli/check_database_schema.php > /dev/null 2>&1; then
    echo "First boot detected — installing Moodle..."
    sudo -u www-data php /var/www/html/admin/cli/install_database.php \
        --agree-license \
        --fullname="Make Nashville Learning" \
        --shortname="MNLearn" \
        --adminuser="admin" \
        --adminpass="${MOODLE_ADMIN_PASSWORD:-changeme}" \
        --adminemail="${MOODLE_ADMIN_EMAIL:-admin@makenashville.org}" \
        || echo "Install failed or already installed"
fi

# Start cron in background (every minute)
(while true; do
    sudo -u www-data php /var/www/html/admin/cli/cron.php > /dev/null 2>&1
    sleep 60
done) &

# Start Apache in foreground
exec apache2-foreground
