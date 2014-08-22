Creates a Semantic Data Collection Changefile for Solve for All based on Javadocs.

Getting the OpenJDK docs (redistributable it seems) in Ubuntu:
sudo apt-get update
sudo apt-get install openjdk-7-doc

ruby main.rb /usr/lib/jvm/java-7-openjdk-amd64/docs/api

should output jdk7-doc.json.bz2 which can then be uploaded.

Also works with JDK 8 Javadocs, but they seem to be non-redistributable.

See https://solveforall.com/docs/developer/semantic_data_collection for more info.
