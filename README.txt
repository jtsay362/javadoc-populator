Creates a document collection changefile based on Javadocs

In Ubuntu:

sudo apt-get update
sudo apt-get install openjdk-7-doc

ruby main.rb /usr/lib/jvm/java-7-openjdk-amd64/docs/api openjdk7.json
bzip2 -kf openjdk7.json

should output openjdk7.json.bz2 which can then be uploaded.

Also works with JDK 8 Javadoc, but that seems to be non-redistributable.
