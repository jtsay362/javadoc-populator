Creates a Document Collection Changefile for Solve for All based on Javadocs.

Getting the OpenJDK docs (redistributable it seems) in Ubuntu:
sudo apt-get update
sudo apt-get install openjdk-7-doc

ruby main.rb /usr/lib/jvm/java-7-openjdk-amd64/docs/api openjdk7.json
bzip2 -kf openjdk7.json

should output openjdk7.json.bz2 which can then be uploaded.

Also works with JDK 8 Javadocs, but they seem to be non-redistributable.

See https://solveforall.com/docs/developer/document_collection for more info.
