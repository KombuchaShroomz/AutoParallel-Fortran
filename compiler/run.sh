folder="../testFiles"
filename="velnw.f95"

originalfile=$folder"/"$filename
parfile=$folder"/par_"$filename

echo ""
echo "Running on "$originalfile
echo ""
./Transformer $originalfile
# ./Transformer $originalfile > treeWalker.out
# python ../utils/astFormatter.py treeWalker.out > treeWalker.ast
# python ../utils/astFormatter.py $parfile > treeWalker.ast