#!/bin/bash

aws s3 cp content/ s3://www.korpisofta.fi/ --recursive --acl public-read

