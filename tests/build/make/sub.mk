out/sub.txt:
	echo "the sub-make ran" > $@
.DEFAULT_GOAL := out/sub.txt
