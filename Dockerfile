# pwpush-postgres
FROM ruby:3.2-slim

LABEL maintainer='pglombardo@hey.com'

ENV APP_ROOT=/opt/PasswordPusher
ENV PATH=${APP_ROOT}:${PATH} HOME=${APP_ROOT}

RUN apt-get update && apt-get install -y curl ca-certificates gnupg

# Required to get the Node.js yarn tool
RUN curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | apt-key add -
RUN echo "deb https://dl.yarnpkg.com/debian/ stable main" | tee /etc/apt/sources.list.d/yarn.list

# Required packages
RUN apt-get update -qq && \
    apt-get install -qq -y --assume-yes build-essential apt-utils libpq-dev git curl tzdata zlib1g-dev nodejs yarn

RUN apt-get install -y \
    build-essential \
    libpq-dev

RUN mkdir -p ${APP_ROOT}
ADD ./ ${APP_ROOT}/

WORKDIR ${APP_ROOT}
EXPOSE 5100

RUN gem install bundler

# Set to development for build steps
ENV RAILS_ENV=development
ENV RACK_ENV=development

# Configure bundler
RUN bundle config set without 'production private test'
RUN bundle config set deployment 'true'

ENV NODE_OPTIONS=--openssl-legacy-provider

RUN bundle install
RUN yarn install

RUN bundle exec rails webpacker:compile

# Set to production for runtime
ENV RAILS_ENV=production
ENV RACK_ENV=production
# DATABASE_URL will be injected at runtime via ECS task definition

ENTRYPOINT ["containers/docker/pwpush-postgres/entrypoint.sh"]
