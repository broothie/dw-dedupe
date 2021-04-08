FROM ruby:2.7.1

WORKDIR /usr/src/app
COPY Gemfile Gemfile.lock puma.rb config.ru ./
COPY app app

RUN gem install bundler -v 2.1.4
RUN bundle config set without development
RUN bundle

CMD ["bundle", "exec", "puma", "-C", "puma.rb"]
