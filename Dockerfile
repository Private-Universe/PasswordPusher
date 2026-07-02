# Setting global arguments
ARG BUNDLE_WITHOUT=development:test
ARG BUNDLE_DEPLOYMENT=true

FROM ruby:4.0.5-alpine AS build-env

# include global args
ARG BUNDLE_WITHOUT
ARG BUNDLE_DEPLOYMENT

LABEL org.opencontainers.image.authors='pglombardo@hey.com'

# Required packages
RUN apk update && apk add --no-cache \
    git \
    build-base \
    musl-dev \
    libc6-compat \
    libpq-dev \
    mariadb-dev \
    nodejs \
    sqlite-dev \
    tzdata \
    yaml-dev \
    yarn \
    pkgconf \
    openssl-dev \
    libffi-dev

ENV APP_ROOT=/opt/PasswordPusher

WORKDIR ${APP_ROOT}
ENV PATH=${APP_ROOT}:${PATH} HOME=${APP_ROOT}

COPY Gemfile Gemfile.lock ./

ENV RACK_ENV=production RAILS_ENV=production

RUN bundle config set without "${BUNDLE_WITHOUT}" \
    && bundle config set deployment "${BUNDLE_DEPLOYMENT}" \
    && bundle install \
    && rm -rf vendor/bundle/ruby/*/cache \
    && rm -rf vendor/bundle/ruby/*/bundler/gems/*/.git \
    && find vendor/bundle/ruby/*/gems/ -name "*.c" -delete \
    && find vendor/bundle/ruby/*/gems/ -name "*.o" -delete

COPY package.json yarn.lock ./

RUN yarn install --frozen-lockfile

COPY ./ ${APP_ROOT}/

RUN SECRET_KEY_BASE_DUMMY=1 bundle exec bootsnap precompile --gemfile
RUN SECRET_KEY_BASE_DUMMY=1 bundle exec bootsnap precompile app/ lib/
RUN SECRET_KEY_BASE_DUMMY=1 bundle exec rails assets:precompile

RUN rm -rf tmp/cache tmp/pids tmp/sockets app/assets/images/features

################## Build done ##################

FROM ruby:4.0.5-alpine

# include global args
ARG BUNDLE_WITHOUT
ARG BUNDLE_DEPLOYMENT

LABEL maintainer='pglombardo@hey.com'

# install packages
RUN apk update && apk add --no-cache \
    bash \
    curl \
    libc6-compat \
    libpq \
    mariadb-connector-c \
    nodejs \
    tzdata \
    yarn \
    jemalloc

# Create a user and group to run the application
ARG UID=1000
ARG GID=1000

ENV LC_CTYPE=UTF-8 LC_ALL=en_US.UTF-8
ENV APP_ROOT=/opt/PasswordPusher
ENV RACK_ENV=production RAILS_ENV=production
ENV LD_PRELOAD=/usr/lib/libjemalloc.so.2

WORKDIR ${APP_ROOT}

RUN addgroup -g "${GID}" pwpusher \
  && adduser -D -u "${UID}" -G pwpusher pwpusher

COPY --from=build-env --chown=pwpusher:pwpusher ${APP_ROOT} ${APP_ROOT}

RUN bundle config set without "${BUNDLE_WITHOUT}" \
    && bundle config set deployment "${BUNDLE_DEPLOYMENT}"

RUN mkdir -p ${APP_ROOT}/storage/db && chown -R pwpusher:pwpusher ${APP_ROOT}/storage

COPY containers/docker/entrypoint.sh /usr/local/bin/docker-entrypoint
COPY containers/docker/worker-entrypoint.sh /usr/local/bin/docker-worker-entrypoint
RUN chmod +x /usr/local/bin/docker-entrypoint /usr/local/bin/docker-worker-entrypoint

RUN rm -rf ${APP_ROOT}/.do \
      ${APP_ROOT}/.github \
      ${APP_ROOT}/app.json \
      ${APP_ROOT}/bin/move_up_stable_tag.sh \
      ${APP_ROOT}/containers \
      ${APP_ROOT}/test \
      ${APP_ROOT}/ct.yaml

RUN touch /opt/PasswordPusher/.env.production && chown pwpusher:pwpusher /opt/PasswordPusher/.env.production

USER pwpusher
EXPOSE 80 443 5100
ENTRYPOINT ["/usr/local/bin/docker-entrypoint"]
